/**
 * HCI-only functional scoreboard monitor
 *
 * Tracks architectural memory contents from granted driver transactions in
 * HCI mode and checks that each completed response:
 *  - corresponds to a previously granted transaction;
 *  - matches the oldest pending transaction, with ordering observed through
 *    the returned read payload when responses are otherwise indistinguishable;
 *  - returns the expected read data;
 *  - leaves every TCDM word equal to the final shadow-memory contents;
 *  - never appears spuriously.
 */

module functional_scoreboard_monitor
  import tb_hci_pkg::*;
#(
  parameter int unsigned N_MASTER = 4,
  parameter int unsigned N_HWPE = 1,
  parameter int unsigned N_BANKS = 16,
  parameter int unsigned BANK_WORDS =
      (TOT_MEM_SIZE * 1024 / N_BANKS) / (DATA_WIDTH / 8),
  // Driver-side grants coincide with memory-side acceptance only without the
  // optional wide-router request FIFO.
  parameter int unsigned ROUTER_FIFO_DEPTH = 0
) (
  input logic                clk_i,
  input logic                rst_ni,
  input logic [DATA_WIDTH-1:0] tcdm_stored_words_i [0:N_BANKS-1][0:BANK_WORDS-1],
  hci_core_intf.monitor      hci_driver_log_if [0:N_MASTER-N_HWPE-1],
  hci_core_intf.monitor      hci_driver_hwpe_if [0:N_HWPE-1]
);

  localparam int unsigned N_LOG_MASTERS = N_MASTER - N_HWPE;
  localparam int unsigned WORD_BYTES = DATA_WIDTH / 8;
  localparam int unsigned HWPE_WORD_BYTES = HWPE_WIDTH_FACT * WORD_BYTES;
  localparam int unsigned MEM_BYTES = TOT_MEM_SIZE * 1024;
  typedef struct packed {
    logic                  is_read;
    logic [DATA_WIDTH-1:0] data;
  } expected_log_rsp_t;

  typedef struct packed {
    logic                                  is_read;
    logic [HWPE_WIDTH_FACT*DATA_WIDTH-1:0]  data;
  } expected_hwpe_rsp_t;

  logic log_req[N_LOG_MASTERS];
  logic log_gnt[N_LOG_MASTERS];
  logic log_r_valid[N_LOG_MASTERS];
  logic log_r_ready[N_LOG_MASTERS];
  logic log_wen[N_LOG_MASTERS];
  logic [ADDR_WIDTH-1:0] log_add[N_LOG_MASTERS];
  logic [DATA_WIDTH-1:0] log_data[N_LOG_MASTERS];
  logic [DATA_WIDTH-1:0] log_r_data[N_LOG_MASTERS];
  logic [WORD_BYTES-1:0] log_be[N_LOG_MASTERS];

  logic hwpe_req[N_HWPE];
  logic hwpe_gnt[N_HWPE];
  logic hwpe_r_valid[N_HWPE];
  logic hwpe_r_ready[N_HWPE];
  logic hwpe_wen[N_HWPE];
  logic [ADDR_WIDTH-1:0] hwpe_add[N_HWPE];
  logic [HWPE_WIDTH_FACT*DATA_WIDTH-1:0] hwpe_data[N_HWPE];
  logic [HWPE_WIDTH_FACT*DATA_WIDTH-1:0] hwpe_r_data[N_HWPE];
  logic [HWPE_WORD_BYTES-1:0] hwpe_be[N_HWPE];

  byte unsigned mem_model [0:MEM_BYTES-1];
  bit failure_seen_q;

  function automatic logic hwpe_rsp_expected(
    input int unsigned master_idx_i,
    input logic        is_read_i
  );
    return is_read_i || !FILTER_WRITE_R_VALID[master_idx_i];
  endfunction

  function automatic logic [DATA_WIDTH-1:0] read_word_from_model(
    input logic [ADDR_WIDTH-1:0] addr_i
  );
    logic [DATA_WIDTH-1:0] ret;
    int unsigned base_addr;
    begin
      base_addr = int'(addr_i);
      if (base_addr + WORD_BYTES > MEM_BYTES) begin
        failure_seen_q = 1'b1;
        $fatal(1, "Scoreboard memory read out of bounds at byte address 0x%0h.", addr_i);
      end
      for (int byte_idx = 0; byte_idx < WORD_BYTES; byte_idx++) begin
        ret[8*byte_idx +: 8] = mem_model[base_addr + byte_idx];
      end
      return ret;
    end
  endfunction

  function automatic logic [HWPE_WIDTH_FACT*DATA_WIDTH-1:0] read_hwpe_data_from_model(
    input logic [ADDR_WIDTH-1:0] addr_i
  );
    logic [HWPE_WIDTH_FACT*DATA_WIDTH-1:0] ret;
    hwpe_addr_data_t lane_addr_data;
    begin
      ret = '0;
      for (int lane_idx = 0; lane_idx < HWPE_WIDTH_FACT; lane_idx++) begin
        lane_addr_data = create_address_and_data_hwpe(addr_i, '0, lane_idx, 1'b0);
        ret[lane_idx*DATA_WIDTH +: DATA_WIDTH] = read_word_from_model(lane_addr_data.address);
      end
      return ret;
    end
  endfunction

  task automatic apply_narrow_write(
    input logic [ADDR_WIDTH-1:0] addr_i,
    input logic [DATA_WIDTH-1:0] data_i,
    input logic [WORD_BYTES-1:0] be_i
  );
    int unsigned base_addr;
    begin
      base_addr = int'(addr_i);
      if (base_addr + WORD_BYTES > MEM_BYTES) begin
        failure_seen_q = 1'b1;
        $fatal(1, "Scoreboard memory write out of bounds at byte address 0x%0h.", addr_i);
      end
      for (int byte_idx = 0; byte_idx < WORD_BYTES; byte_idx++) begin
        if (be_i[byte_idx]) begin
          mem_model[base_addr + byte_idx] = data_i[8*byte_idx +: 8];
        end
      end
    end
  endtask

  task automatic apply_hwpe_write(
    input logic [ADDR_WIDTH-1:0]                     addr_i,
    input logic [HWPE_WIDTH_FACT*DATA_WIDTH-1:0]    data_i,
    input logic [HWPE_WORD_BYTES-1:0]               be_i
  );
    hwpe_addr_data_t lane_addr_data;
    begin
      for (int lane_idx = 0; lane_idx < HWPE_WIDTH_FACT; lane_idx++) begin
        lane_addr_data = create_address_and_data_hwpe(addr_i, data_i, lane_idx, 1'b0);
        apply_narrow_write(
          lane_addr_data.address,
          lane_addr_data.data,
          be_i[lane_idx*WORD_BYTES +: WORD_BYTES]
        );
      end
    end
  endtask

  initial begin
    failure_seen_q = 1'b0;
    if (ROUTER_FIFO_DEPTH != 0) begin
      failure_seen_q = 1'b1;
      $fatal(
        1,
        "functional_scoreboard_monitor requires ROUTER_FIFO_DEPTH=0; got %0d.",
        ROUTER_FIFO_DEPTH
      );
    end
    for (int byte_idx = 0; byte_idx < MEM_BYTES; byte_idx++) begin
      mem_model[byte_idx] = 8'hff;
    end
  end

  generate
    for (genvar ii = 0; ii < N_LOG_MASTERS; ii++) begin : gen_log_bind
      assign log_req[ii] = hci_driver_log_if[ii].req;
      assign log_gnt[ii] = hci_driver_log_if[ii].gnt;
      assign log_r_valid[ii] = hci_driver_log_if[ii].r_valid;
      assign log_r_ready[ii] = hci_driver_log_if[ii].r_ready;
      assign log_wen[ii] = hci_driver_log_if[ii].wen;
      assign log_add[ii] = hci_driver_log_if[ii].add[ADDR_WIDTH-1:0];
      assign log_data[ii] = hci_driver_log_if[ii].data;
      assign log_r_data[ii] = hci_driver_log_if[ii].r_data;
      assign log_be[ii] = hci_driver_log_if[ii].be;
    end

    for (genvar ii = 0; ii < N_HWPE; ii++) begin : gen_hwpe_bind
      assign hwpe_req[ii] = hci_driver_hwpe_if[ii].req;
      assign hwpe_gnt[ii] = hci_driver_hwpe_if[ii].gnt;
      assign hwpe_r_valid[ii] = hci_driver_hwpe_if[ii].r_valid;
      assign hwpe_r_ready[ii] = hci_driver_hwpe_if[ii].r_ready;
      assign hwpe_wen[ii] = hci_driver_hwpe_if[ii].wen;
      assign hwpe_add[ii] = hci_driver_hwpe_if[ii].add[ADDR_WIDTH-1:0];
      assign hwpe_data[ii] = hci_driver_hwpe_if[ii].data;
      assign hwpe_r_data[ii] = hci_driver_hwpe_if[ii].r_data;
      assign hwpe_be[ii] = hci_driver_hwpe_if[ii].be;
    end
  endgenerate

  expected_log_rsp_t expected_log_rsp_q[N_LOG_MASTERS][$];
  expected_hwpe_rsp_t expected_hwpe_rsp_q[N_HWPE][$];
  int unsigned debug_log_gnt_count_q[N_LOG_MASTERS];
  int unsigned debug_log_rsp_count_q[N_LOG_MASTERS];
  int unsigned debug_hwpe_gnt_count_q[N_HWPE];
  int unsigned debug_hwpe_rsp_count_q[N_HWPE];

  always @(posedge clk_i or negedge rst_ni) begin
    expected_log_rsp_t exp_log_rsp;
    expected_log_rsp_t new_log_rsp;
    expected_hwpe_rsp_t exp_hwpe_rsp;
    expected_hwpe_rsp_t new_hwpe_rsp;
    if (!rst_ni) begin
      failure_seen_q = 1'b0;
      for (int ii = 0; ii < N_LOG_MASTERS; ii++) begin
        expected_log_rsp_q[ii].delete();
        debug_log_gnt_count_q[ii] = '0;
        debug_log_rsp_count_q[ii] = '0;
      end
      for (int ii = 0; ii < N_HWPE; ii++) begin
        expected_hwpe_rsp_q[ii].delete();
        debug_hwpe_gnt_count_q[ii] = '0;
        debug_hwpe_rsp_count_q[ii] = '0;
      end
    end else begin
      // Phase 1: retire responses only from transactions that were already
      // pending before this edge. A new grant cannot justify a response on the
      // same edge.
      for (int ii = 0; ii < N_LOG_MASTERS; ii++) begin
        if (log_r_valid[ii] && log_r_ready[ii]) begin
          debug_log_rsp_count_q[ii] = debug_log_rsp_count_q[ii] + 1;
          if (expected_log_rsp_q[ii].size() == 0) begin
            failure_seen_q = 1'b1;
            $fatal(
              1,
              "Spurious response on master_log_%0d: r_data=0x%0h gnt_count=%0d rsp_count=%0d",
              ii,
              log_r_data[ii],
              debug_log_gnt_count_q[ii],
              debug_log_rsp_count_q[ii]
            );
          end else begin
            exp_log_rsp = expected_log_rsp_q[ii].pop_front();
            if (exp_log_rsp.is_read && (log_r_data[ii] !== exp_log_rsp.data)) begin
              failure_seen_q = 1'b1;
              $fatal(
                1,
                "Read-data mismatch on master_log_%0d: expected 0x%0h, got 0x%0h",
                ii,
                exp_log_rsp.data,
                log_r_data[ii]
              );
            end
          end
        end
      end

      for (int ii = 0; ii < N_HWPE; ii++) begin
        if (hwpe_r_valid[ii] && hwpe_r_ready[ii]) begin
          debug_hwpe_rsp_count_q[ii] = debug_hwpe_rsp_count_q[ii] + 1;
          if (expected_hwpe_rsp_q[ii].size() == 0) begin
            failure_seen_q = 1'b1;
            $fatal(
              1,
              "Spurious response on master_hwpe_%0d: gnt_count=%0d rsp_count=%0d",
              ii,
              debug_hwpe_gnt_count_q[ii],
              debug_hwpe_rsp_count_q[ii]
            );
          end else begin
            exp_hwpe_rsp = expected_hwpe_rsp_q[ii].pop_front();
            if (exp_hwpe_rsp.is_read && (hwpe_r_data[ii] !== exp_hwpe_rsp.data)) begin
              failure_seen_q = 1'b1;
              $fatal(
                1,
                "Read-data mismatch on master_hwpe_%0d: expected 0x%0h, got 0x%0h",
                ii,
                exp_hwpe_rsp.data,
                hwpe_r_data[ii]
              );
            end
          end
        end
      end

      // Phase 2: capture newly granted transactions against this cycle's
      // pre-write memory image.
      for (int ii = 0; ii < N_LOG_MASTERS; ii++) begin
        if (log_req[ii] && log_gnt[ii]) begin
          debug_log_gnt_count_q[ii] = debug_log_gnt_count_q[ii] + 1;
          new_log_rsp.is_read = log_wen[ii];
          new_log_rsp.data = log_wen[ii] ? read_word_from_model(log_add[ii]) : '0;
          expected_log_rsp_q[ii].push_back(new_log_rsp);
        end
      end

      for (int ii = 0; ii < N_HWPE; ii++) begin
        if (hwpe_req[ii] && hwpe_gnt[ii]) begin
          debug_hwpe_gnt_count_q[ii] = debug_hwpe_gnt_count_q[ii] + 1;
          if (hwpe_rsp_expected(ii, hwpe_wen[ii])) begin
            new_hwpe_rsp.is_read = hwpe_wen[ii];
            new_hwpe_rsp.data = hwpe_wen[ii] ? read_hwpe_data_from_model(hwpe_add[ii]) : '0;
            expected_hwpe_rsp_q[ii].push_back(new_hwpe_rsp);
          end
        end
      end

      // Phase 3: apply all writes after reads have sampled this cycle's
      // pre-write memory state.
      for (int ii = 0; ii < N_LOG_MASTERS; ii++) begin
        if (log_req[ii] && log_gnt[ii] && !log_wen[ii]) begin
          apply_narrow_write(
            log_add[ii],
            log_data[ii],
            log_be[ii]
          );
        end
      end

      for (int ii = 0; ii < N_HWPE; ii++) begin
        if (hwpe_req[ii] && hwpe_gnt[ii] && !hwpe_wen[ii]) begin
          apply_hwpe_write(
            hwpe_add[ii],
            hwpe_data[ii],
            hwpe_be[ii]
          );
        end
      end
    end
  end

  final begin
    bit pass;
    int unsigned content_mismatches;
    logic [DATA_WIDTH-1:0] expected_word;
    int unsigned global_word_idx;
    int unsigned global_byte_idx;

    pass = 1'b1;
    content_mismatches = 0;
    for (int ii = 0; ii < N_LOG_MASTERS; ii++) begin
      if (expected_log_rsp_q[ii].size() != 0) begin
        $error(
          "master_log_%0d finished with %0d outstanding expected responses",
          ii,
          expected_log_rsp_q[ii].size()
        );
        pass = 1'b0;
      end
    end
    for (int ii = 0; ii < N_HWPE; ii++) begin
      if (expected_hwpe_rsp_q[ii].size() != 0) begin
        $error(
          "master_hwpe_%0d finished with %0d outstanding expected responses",
          ii,
          expected_hwpe_rsp_q[ii].size()
        );
        pass = 1'b0;
      end
    end

    if (N_BANKS * BANK_WORDS * WORD_BYTES != MEM_BYTES) begin
      $error(
        "Scoreboard memory geometry mismatch: banks=%0d words_per_bank=%0d word_bytes=%0d mem_bytes=%0d",
        N_BANKS,
        BANK_WORDS,
        WORD_BYTES,
        MEM_BYTES
      );
      pass = 1'b0;
    end else begin
      for (int bank_idx = 0; bank_idx < N_BANKS; bank_idx++) begin
        for (int bank_word_idx = 0; bank_word_idx < BANK_WORDS; bank_word_idx++) begin
          global_word_idx = bank_word_idx * N_BANKS + bank_idx;
          global_byte_idx = global_word_idx * WORD_BYTES;
          for (int byte_idx = 0; byte_idx < WORD_BYTES; byte_idx++) begin
            expected_word[8*byte_idx +: 8] = mem_model[global_byte_idx + byte_idx];
          end
          if (tcdm_stored_words_i[bank_idx][bank_word_idx] !== expected_word) begin
            if (content_mismatches < 8) begin
              $error(
                "Stored-content mismatch on bank %0d word %0d: expected 0x%0h, got 0x%0h",
                bank_idx,
                bank_word_idx,
                expected_word,
                tcdm_stored_words_i[bank_idx][bank_word_idx]
              );
            end
            content_mismatches++;
          end
        end
      end
      if (content_mismatches != 0) begin
        $error("Functional scoreboard found %0d stored-content mismatches.", content_mismatches);
        pass = 1'b0;
      end
    end

    if (pass && !failure_seen_q) begin
      $display(
        "Functional scoreboard monitor: PASS (responses and %0d stored words)",
        N_BANKS * BANK_WORDS
      );
    end
  end

endmodule
