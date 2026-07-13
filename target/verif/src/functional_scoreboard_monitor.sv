/**
 * HCI-only functional scoreboard monitor
 *
 * Tracks architectural memory contents from granted driver transactions in
 * HCI mode and checks that each completed response:
 *  - corresponds to a previously granted transaction;
 *  - arrives in per-master FIFO order;
 *  - returns the expected read data;
 *  - never appears spuriously.
 */

module functional_scoreboard_monitor
  import tb_hci_pkg::*;
#(
  parameter int unsigned N_MASTER = 4,
  parameter int unsigned N_HWPE = 1,
  parameter bit CHECK_LOG_R_ID = 1'b0
) (
  input logic                clk_i,
  input logic                rst_ni,
  input logic [N_MASTER-1:0] end_resp_i,
  hci_core_intf.monitor      hci_driver_log_if [0:N_MASTER-N_HWPE-1],
  hci_core_intf.monitor      hci_driver_hwpe_if [0:N_HWPE-1]
);

  localparam int unsigned N_LOG_MASTERS_LOCAL = N_MASTER - N_HWPE;
  localparam int unsigned WORD_BYTES = DATA_WIDTH / 8;
  localparam int unsigned HWPE_WORD_BYTES = HWPE_WIDTH_FACT * WORD_BYTES;
  localparam int unsigned MEM_BYTES = TOT_MEM_SIZE * 1024;
  localparam int unsigned MAX_PENDING_RSP = 1024;
  typedef struct packed {
    logic                  is_read;
    logic [IW_cores-1:0]     id;
    logic [DATA_WIDTH-1:0]   data;
  } expected_log_rsp_t;

  typedef struct packed {
    logic                                   is_read;
    logic [IW_hwpe-1:0]                      id;
    logic [HWPE_WIDTH_FACT*DATA_WIDTH-1:0]  data;
  } expected_hwpe_rsp_t;

  logic log_req[N_LOG_MASTERS_LOCAL];
  logic log_gnt[N_LOG_MASTERS_LOCAL];
  logic log_r_valid[N_LOG_MASTERS_LOCAL];
  logic log_r_ready[N_LOG_MASTERS_LOCAL];
  logic log_wen[N_LOG_MASTERS_LOCAL];
  logic [IW_cores-1:0] log_id[N_LOG_MASTERS_LOCAL];
  logic [IW_cores-1:0] log_r_id[N_LOG_MASTERS_LOCAL];
  logic [ADDR_WIDTH-1:0] log_add[N_LOG_MASTERS_LOCAL];
  logic [DATA_WIDTH-1:0] log_data[N_LOG_MASTERS_LOCAL];
  logic [DATA_WIDTH-1:0] log_r_data[N_LOG_MASTERS_LOCAL];
  logic [WORD_BYTES-1:0] log_be[N_LOG_MASTERS_LOCAL];

  logic hwpe_req[N_HWPE];
  logic hwpe_gnt[N_HWPE];
  logic hwpe_r_valid[N_HWPE];
  logic hwpe_r_ready[N_HWPE];
  logic hwpe_wen[N_HWPE];
  logic [IW_hwpe-1:0] hwpe_id[N_HWPE];
  logic [IW_hwpe-1:0] hwpe_r_id[N_HWPE];
  logic [ADDR_WIDTH-1:0] hwpe_add[N_HWPE];
  logic [HWPE_WIDTH_FACT*DATA_WIDTH-1:0] hwpe_data[N_HWPE];
  logic [HWPE_WIDTH_FACT*DATA_WIDTH-1:0] hwpe_r_data[N_HWPE];
  logic [HWPE_WORD_BYTES-1:0] hwpe_be[N_HWPE];

  byte unsigned mem_model [0:MEM_BYTES-1];

  function automatic logic [DATA_WIDTH-1:0] read_word_from_model(
    input logic [ADDR_WIDTH-1:0] addr_i
  );
    logic [DATA_WIDTH-1:0] ret;
    int unsigned base_addr;
    begin
      base_addr = int'(addr_i);
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
    for (int byte_idx = 0; byte_idx < MEM_BYTES; byte_idx++) begin
      mem_model[byte_idx] = 8'hff;
    end
  end

  generate
    for (genvar gi = 0; gi < N_LOG_MASTERS_LOCAL; gi++) begin : gen_log_bind
      assign log_req[gi] = hci_driver_log_if[gi].req;
      assign log_gnt[gi] = hci_driver_log_if[gi].gnt;
      assign log_r_valid[gi] = hci_driver_log_if[gi].r_valid;
      assign log_r_ready[gi] = hci_driver_log_if[gi].r_ready;
      assign log_wen[gi] = hci_driver_log_if[gi].wen;
      assign log_id[gi] = hci_driver_log_if[gi].id[IW_cores-1:0];
      assign log_r_id[gi] = hci_driver_log_if[gi].r_id[IW_cores-1:0];
      assign log_add[gi] = hci_driver_log_if[gi].add[ADDR_WIDTH-1:0];
      assign log_data[gi] = hci_driver_log_if[gi].data;
      assign log_r_data[gi] = hci_driver_log_if[gi].r_data;
      assign log_be[gi] = hci_driver_log_if[gi].be;
    end

    for (genvar gi = 0; gi < N_HWPE; gi++) begin : gen_hwpe_bind
      assign hwpe_req[gi] = hci_driver_hwpe_if[gi].req;
      assign hwpe_gnt[gi] = hci_driver_hwpe_if[gi].gnt;
      assign hwpe_r_valid[gi] = hci_driver_hwpe_if[gi].r_valid;
      assign hwpe_r_ready[gi] = hci_driver_hwpe_if[gi].r_ready;
      assign hwpe_wen[gi] = hci_driver_hwpe_if[gi].wen;
      assign hwpe_id[gi] = hci_driver_hwpe_if[gi].id[IW_hwpe-1:0];
      assign hwpe_r_id[gi] = hci_driver_hwpe_if[gi].r_id[IW_hwpe-1:0];
      assign hwpe_add[gi] = hci_driver_hwpe_if[gi].add[ADDR_WIDTH-1:0];
      assign hwpe_data[gi] = hci_driver_hwpe_if[gi].data;
      assign hwpe_r_data[gi] = hci_driver_hwpe_if[gi].r_data;
      assign hwpe_be[gi] = hci_driver_hwpe_if[gi].be;
    end
  endgenerate

  expected_log_rsp_t expected_log_rsp_mem[N_LOG_MASTERS_LOCAL][MAX_PENDING_RSP];
  expected_hwpe_rsp_t expected_hwpe_rsp_mem[N_HWPE][MAX_PENDING_RSP];
  int unsigned expected_log_head_q[N_LOG_MASTERS_LOCAL];
  int unsigned expected_log_count_q[N_LOG_MASTERS_LOCAL];
  int unsigned expected_hwpe_head_q[N_HWPE];
  int unsigned expected_hwpe_count_q[N_HWPE];
  int unsigned debug_log_gnt_count_q[N_LOG_MASTERS_LOCAL];
  int unsigned debug_log_rsp_count_q[N_LOG_MASTERS_LOCAL];
  int unsigned debug_hwpe_gnt_count_q[N_HWPE];
  int unsigned debug_hwpe_rsp_count_q[N_HWPE];

  always @(posedge clk_i or negedge rst_ni) begin
    expected_log_rsp_t exp_log_rsp;
    expected_log_rsp_t new_log_rsp;
    expected_hwpe_rsp_t exp_hwpe_rsp;
    expected_hwpe_rsp_t new_hwpe_rsp;
    if (!rst_ni) begin
      for (int i = 0; i < N_LOG_MASTERS_LOCAL; i++) begin
        expected_log_head_q[i] = '0;
        expected_log_count_q[i] = '0;
        debug_log_gnt_count_q[i] = '0;
        debug_log_rsp_count_q[i] = '0;
      end
      for (int i = 0; i < N_HWPE; i++) begin
        expected_hwpe_head_q[i] = '0;
        expected_hwpe_count_q[i] = '0;
        debug_hwpe_gnt_count_q[i] = '0;
        debug_hwpe_rsp_count_q[i] = '0;
      end
    end else begin
      // Phase 1: capture all newly granted transactions against the pre-write
      // memory image of this cycle. In LOG mode the HWPE split/recombine path
      // can expose a wide grant and the corresponding wide response in the same
      // cycle at the driver-facing interface, so grants must enter the queue
      // before same-cycle responses are retired.
      for (int i = 0; i < N_LOG_MASTERS_LOCAL; i++) begin
        int unsigned log_tail_idx;
        if (log_req[i] && log_gnt[i]) begin
          if (expected_log_count_q[i] == MAX_PENDING_RSP) begin
            $fatal(1, "master_log_%0d scoreboard overflow", i);
          end
          debug_log_gnt_count_q[i] = debug_log_gnt_count_q[i] + 1;
          new_log_rsp.is_read = log_wen[i];
          new_log_rsp.id = log_id[i];
          new_log_rsp.data = log_wen[i] ? read_word_from_model(log_add[i]) : '0;
          log_tail_idx = (expected_log_head_q[i] + expected_log_count_q[i]) % MAX_PENDING_RSP;
          expected_log_rsp_mem[i][log_tail_idx] = new_log_rsp;
          expected_log_count_q[i] = expected_log_count_q[i] + 1;
        end
      end

      for (int i = 0; i < N_HWPE; i++) begin
        int unsigned hwpe_tail_idx;
        if (hwpe_req[i] && hwpe_gnt[i]) begin
          if (expected_hwpe_count_q[i] == MAX_PENDING_RSP) begin
            $fatal(1, "master_hwpe_%0d scoreboard overflow", i);
          end
          debug_hwpe_gnt_count_q[i] = debug_hwpe_gnt_count_q[i] + 1;
          new_hwpe_rsp.is_read = hwpe_wen[i];
          new_hwpe_rsp.id = hwpe_id[i];
          new_hwpe_rsp.data = hwpe_wen[i] ? read_hwpe_data_from_model(hwpe_add[i]) : '0;
          hwpe_tail_idx = (expected_hwpe_head_q[i] + expected_hwpe_count_q[i]) % MAX_PENDING_RSP;
          expected_hwpe_rsp_mem[i][hwpe_tail_idx] = new_hwpe_rsp;
          expected_hwpe_count_q[i] = expected_hwpe_count_q[i] + 1;
        end
      end

      // Phase 2: retire and validate responses using the expected transaction
      // queues updated above.
      for (int i = 0; i < N_LOG_MASTERS_LOCAL; i++) begin
        if (log_r_valid[i] && log_r_ready[i]) begin
          debug_log_rsp_count_q[i] = debug_log_rsp_count_q[i] + 1;
          if (expected_log_count_q[i] == 0) begin
            $fatal(
              1,
              "Spurious response on master_log_%0d: r_id=0x%0h r_data=0x%0h gnt_count=%0d rsp_count=%0d",
              i,
              log_r_id[i],
              log_r_data[i],
              debug_log_gnt_count_q[i],
              debug_log_rsp_count_q[i]
            );
          end else begin
            exp_log_rsp = expected_log_rsp_mem[i][expected_log_head_q[i]];
            expected_log_head_q[i] = (expected_log_head_q[i] + 1) % MAX_PENDING_RSP;
            expected_log_count_q[i] = expected_log_count_q[i] - 1;
            if (CHECK_LOG_R_ID) begin
              // Use 4-state comparisons so unknown/X response IDs are not
              // silently accepted by the monitor when the path is expected to
              // preserve IDs meaningfully.
              if (log_r_id[i] !== exp_log_rsp.id) begin
                $fatal(
                  1,
                  "Response-ID mismatch on master_log_%0d: expected 0x%0h, got 0x%0h",
                  i,
                  exp_log_rsp.id,
                  log_r_id[i]
                );
              end
            end
            if (exp_log_rsp.is_read) begin
              if (log_r_data[i] !== exp_log_rsp.data) begin
                $fatal(
                  1,
                  "Read-data mismatch on master_log_%0d: expected 0x%0h, got 0x%0h",
                  i,
                  exp_log_rsp.data,
                  log_r_data[i]
                );
              end
            end
          end
        end
      end

      for (int i = 0; i < N_HWPE; i++) begin
        if (hwpe_r_valid[i] && hwpe_r_ready[i]) begin
          debug_hwpe_rsp_count_q[i] = debug_hwpe_rsp_count_q[i] + 1;
          if (expected_hwpe_count_q[i] == 0) begin
            $fatal(
              1,
              "Spurious response on master_hwpe_%0d: r_id=0x%0h gnt_count=%0d rsp_count=%0d",
              i,
              hwpe_r_id[i],
              debug_hwpe_gnt_count_q[i],
              debug_hwpe_rsp_count_q[i]
            );
          end else begin
            exp_hwpe_rsp = expected_hwpe_rsp_mem[i][expected_hwpe_head_q[i]];
            expected_hwpe_head_q[i] = (expected_hwpe_head_q[i] + 1) % MAX_PENDING_RSP;
            expected_hwpe_count_q[i] = expected_hwpe_count_q[i] - 1;
            if (exp_hwpe_rsp.is_read) begin
              if (hwpe_r_data[i] !== exp_hwpe_rsp.data) begin
                $fatal(
                  1,
                  "Read-data mismatch on master_hwpe_%0d: expected 0x%0h, got 0x%0h",
                  i,
                  exp_hwpe_rsp.data,
                  hwpe_r_data[i]
                );
              end
            end
          end
        end
      end

      // Phase 3: apply all writes after reads have sampled this cycle's
      // pre-write memory state.
      for (int i = 0; i < N_LOG_MASTERS_LOCAL; i++) begin
        if (log_req[i] && log_gnt[i] && !log_wen[i]) begin
          apply_narrow_write(
            log_add[i],
            log_data[i],
            log_be[i]
          );
        end
      end

      for (int i = 0; i < N_HWPE; i++) begin
        if (hwpe_req[i] && hwpe_gnt[i] && !hwpe_wen[i]) begin
          apply_hwpe_write(
            hwpe_add[i],
            hwpe_data[i],
            hwpe_be[i]
          );
        end
      end
    end
  end

  final begin
    bit pass;
    pass = 1'b1;
    for (int i = 0; i < N_LOG_MASTERS_LOCAL; i++) begin
      if (expected_log_count_q[i] != 0) begin
        $error(
          "master_log_%0d finished with %0d outstanding expected responses",
          i,
          expected_log_count_q[i]
        );
        pass = 1'b0;
      end
    end
    for (int i = 0; i < N_HWPE; i++) begin
      if (expected_hwpe_count_q[i] != 0) begin
        $error(
          "master_hwpe_%0d finished with %0d outstanding expected responses",
          i,
          expected_hwpe_count_q[i]
        );
        pass = 1'b0;
      end
    end
    if (pass) begin
      $display("Functional scoreboard monitor: PASS");
    end
  end

endmodule
