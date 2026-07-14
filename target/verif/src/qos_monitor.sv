/**
 * HCI branch-arbitration QoS monitor
 *
 * Replays the wide-vs-narrow arbiter service-window policy on conflict cycles,
 * checks the post-arbiter bank selection, and also sanity-checks the
 * conflict-free pass-through cases. It reports the observed number of conflict
 * cycles served by the narrow and wide branches.
 */

module qos_monitor
  import hci_package::*;
  import tb_hci_pkg::*;
#(
  parameter int unsigned N_BANKS = 16
) (
  input logic                clk_i,
  input logic                rst_ni,
  input hci_interconnect_ctrl_t ctrl_i,
  hci_core_intf.monitor      narrow_bank_if [0:N_BANKS-1],
  hci_core_intf.monitor      wide_bank_if [0:N_BANKS-1],
  hci_core_intf.monitor      mem_bank_if [0:N_BANKS-1]
);

  int unsigned conflict_cycles_q;
  int unsigned high_prio_conflict_cycles_q;
  int unsigned low_service_conflict_cycles_q;
  logic [7:0]  priority_cnt_q;
  logic narrow_req[N_BANKS];
  logic wide_req[N_BANKS];
  logic mem_req[N_BANKS];
  logic narrow_gnt[N_BANKS];
  logic wide_gnt[N_BANKS];
  logic [ADDR_WIDTH-1:0] narrow_add[N_BANKS];
  logic [ADDR_WIDTH-1:0] wide_add[N_BANKS];
  logic [ADDR_WIDTH-1:0] mem_add[N_BANKS];
  logic narrow_wen[N_BANKS];
  logic wide_wen[N_BANKS];
  logic mem_wen[N_BANKS];
  logic [DATA_WIDTH-1:0] narrow_data[N_BANKS];
  logic [DATA_WIDTH-1:0] wide_data[N_BANKS];
  logic [DATA_WIDTH-1:0] mem_data[N_BANKS];
  logic [DATA_WIDTH/8-1:0] narrow_be[N_BANKS];
  logic [DATA_WIDTH/8-1:0] wide_be[N_BANKS];
  logic [DATA_WIDTH/8-1:0] mem_be[N_BANKS];

  generate
    for (genvar ii = 0; ii < N_BANKS; ii++) begin : gen_bind
      assign narrow_req[ii] = narrow_bank_if[ii].req;
      assign wide_req[ii] = wide_bank_if[ii].req;
      assign mem_req[ii] = mem_bank_if[ii].req;
      assign narrow_gnt[ii] = narrow_bank_if[ii].gnt;
      assign wide_gnt[ii] = wide_bank_if[ii].gnt;
      assign narrow_add[ii] = narrow_bank_if[ii].add;
      assign wide_add[ii] = wide_bank_if[ii].add;
      assign mem_add[ii] = mem_bank_if[ii].add;
      assign narrow_wen[ii] = narrow_bank_if[ii].wen;
      assign wide_wen[ii] = wide_bank_if[ii].wen;
      assign mem_wen[ii] = mem_bank_if[ii].wen;
      assign narrow_data[ii] = narrow_bank_if[ii].data;
      assign wide_data[ii] = wide_bank_if[ii].data;
      assign mem_data[ii] = mem_bank_if[ii].data;
      assign narrow_be[ii] = narrow_bank_if[ii].be;
      assign wide_be[ii] = wide_bank_if[ii].be;
      assign mem_be[ii] = mem_bank_if[ii].be;
    end
  endgenerate

  function automatic logic in_low_service_window(
    input logic [7:0] priority_cnt_i,
    input logic       any_conflict_i
  );
    if (ctrl_i.priority_cnt_numerator == 0) begin
      return 1'b0;
    end
    return any_conflict_i
        && (priority_cnt_i >= ctrl_i.priority_cnt_numerator)
        && (priority_cnt_i < ctrl_i.priority_cnt_denominator);
  endfunction

  task automatic check_expected_source(
    input int unsigned bank_idx_i,
    input logic        expected_req_i,
    input logic [ADDR_WIDTH-1:0] expected_add_i,
    input logic        expected_wen_i,
    input logic [DATA_WIDTH-1:0] expected_data_i,
    input logic [DATA_WIDTH/8-1:0] expected_be_i
  );
    if (expected_req_i) begin
      if (mem_req[bank_idx_i] !== 1'b1
          || mem_add[bank_idx_i] !== expected_add_i
          || mem_wen[bank_idx_i] !== expected_wen_i
          || mem_data[bank_idx_i] !== expected_data_i
          || mem_be[bank_idx_i] !== expected_be_i) begin
        $fatal(
          1,
          "QoS mismatch on bank %0d: post-arbiter bank interface did not match the expected source.",
          bank_idx_i
        );
      end
    end else begin
      if (mem_req[bank_idx_i] !== 1'b0) begin
        $fatal(
          1,
          "QoS mismatch on bank %0d: post-arbiter bank interface should have been idle.",
          bank_idx_i
        );
      end
    end
  endtask

  always_ff @(posedge clk_i or negedge rst_ni) begin
    logic any_conflict;
    logic low_service_window;

    if (!rst_ni) begin
      conflict_cycles_q <= '0;
      high_prio_conflict_cycles_q <= '0;
      low_service_conflict_cycles_q <= '0;
      priority_cnt_q <= '0;
    end else begin
      any_conflict = 1'b0;
      for (int ii = 0; ii < N_BANKS; ii++) begin
        if (narrow_req[ii] && wide_req[ii]) begin
          any_conflict = 1'b1;
        end
      end

      low_service_window = in_low_service_window(priority_cnt_q, any_conflict);

      if (any_conflict) begin
        logic high_req_bank;
        logic low_req_bank;
        logic high_gnt_bank;
        logic low_gnt_bank;
        logic [ADDR_WIDTH-1:0] high_add_bank;
        logic [ADDR_WIDTH-1:0] low_add_bank;
        logic high_wen_bank;
        logic low_wen_bank;
        logic [DATA_WIDTH-1:0] high_data_bank;
        logic [DATA_WIDTH-1:0] low_data_bank;
        logic [DATA_WIDTH/8-1:0] high_be_bank;
        logic [DATA_WIDTH/8-1:0] low_be_bank;

        conflict_cycles_q <= conflict_cycles_q + 1;
        if (low_service_window) begin
          low_service_conflict_cycles_q <= low_service_conflict_cycles_q + 1;
        end else begin
          high_prio_conflict_cycles_q <= high_prio_conflict_cycles_q + 1;
        end

        for (int ii = 0; ii < N_BANKS; ii++) begin
          if (ctrl_i.invert_prio) begin
            high_req_bank = wide_req[ii];
            low_req_bank = narrow_req[ii];
            high_gnt_bank = wide_gnt[ii];
            low_gnt_bank = narrow_gnt[ii];
            high_add_bank = wide_add[ii];
            low_add_bank = narrow_add[ii];
            high_wen_bank = wide_wen[ii];
            low_wen_bank = narrow_wen[ii];
            high_data_bank = wide_data[ii];
            low_data_bank = narrow_data[ii];
            high_be_bank = wide_be[ii];
            low_be_bank = narrow_be[ii];
          end else begin
            high_req_bank = narrow_req[ii];
            low_req_bank = wide_req[ii];
            high_gnt_bank = narrow_gnt[ii];
            low_gnt_bank = wide_gnt[ii];
            high_add_bank = narrow_add[ii];
            low_add_bank = wide_add[ii];
            high_wen_bank = narrow_wen[ii];
            low_wen_bank = wide_wen[ii];
            high_data_bank = narrow_data[ii];
            low_data_bank = wide_data[ii];
            high_be_bank = narrow_be[ii];
            low_be_bank = wide_be[ii];
          end

          if (low_service_window) begin
            check_expected_source(ii, low_req_bank, low_add_bank, low_wen_bank, low_data_bank, low_be_bank);
          end else if (high_req_bank) begin
            check_expected_source(ii, high_req_bank, high_add_bank, high_wen_bank, high_data_bank, high_be_bank);
          end else begin
            check_expected_source(ii, low_req_bank, low_add_bank, low_wen_bank, low_data_bank, low_be_bank);
          end

          if (RANDOM_GNT == 0 && high_req_bank && low_req_bank) begin
            if (low_service_window) begin
              if (high_gnt_bank !== 1'b0 || low_gnt_bank !== 1'b1) begin
                $fatal(
                  1,
                  "QoS grant mismatch on bank %0d: expected logical low-priority branch to win conflict.",
                  ii
                );
              end
            end else begin
              if (high_gnt_bank !== 1'b1 || low_gnt_bank !== 1'b0) begin
                $fatal(
                  1,
                  "QoS grant mismatch on bank %0d: expected logical high-priority branch to win conflict.",
                  ii
                );
              end
            end
          end
        end

        if (priority_cnt_q == ctrl_i.priority_cnt_denominator - 1) begin
          priority_cnt_q <= '0;
        end else begin
          priority_cnt_q <= priority_cnt_q + 1;
        end
      end else begin
        logic high_req_bank;
        logic low_req_bank;
        logic [ADDR_WIDTH-1:0] high_add_bank;
        logic [ADDR_WIDTH-1:0] low_add_bank;
        logic high_wen_bank;
        logic low_wen_bank;
        logic [DATA_WIDTH-1:0] high_data_bank;
        logic [DATA_WIDTH-1:0] low_data_bank;
        logic [DATA_WIDTH/8-1:0] high_be_bank;
        logic [DATA_WIDTH/8-1:0] low_be_bank;

        for (int ii = 0; ii < N_BANKS; ii++) begin
          if (ctrl_i.invert_prio) begin
            high_req_bank = wide_req[ii];
            low_req_bank = narrow_req[ii];
            high_add_bank = wide_add[ii];
            low_add_bank = narrow_add[ii];
            high_wen_bank = wide_wen[ii];
            low_wen_bank = narrow_wen[ii];
            high_data_bank = wide_data[ii];
            low_data_bank = narrow_data[ii];
            high_be_bank = wide_be[ii];
            low_be_bank = narrow_be[ii];
          end else begin
            high_req_bank = narrow_req[ii];
            low_req_bank = wide_req[ii];
            high_add_bank = narrow_add[ii];
            low_add_bank = wide_add[ii];
            high_wen_bank = narrow_wen[ii];
            low_wen_bank = wide_wen[ii];
            high_data_bank = narrow_data[ii];
            low_data_bank = wide_data[ii];
            high_be_bank = narrow_be[ii];
            low_be_bank = wide_be[ii];
          end

          if (high_req_bank) begin
            check_expected_source(ii, high_req_bank, high_add_bank, high_wen_bank, high_data_bank, high_be_bank);
          end else begin
            check_expected_source(ii, low_req_bank, low_add_bank, low_wen_bank, low_data_bank, low_be_bank);
          end
        end
      end
    end
  end

  final begin
    real low_window_share_pct;
    string low_branch_str;

    if (conflict_cycles_q == 0) begin
      $display("QoS monitor: no conflict cycles observed.");
    end else begin
      low_window_share_pct = 100.0 * real'(low_service_conflict_cycles_q) / real'(conflict_cycles_q);
      low_branch_str = ctrl_i.invert_prio ? "narrow" : "wide";
      $display(
        "QoS monitor: conflicts=%0d high_window=%0d low_window=%0d invert_prio=%0d num=%0d den=%0d",
        conflict_cycles_q,
        high_prio_conflict_cycles_q,
        low_service_conflict_cycles_q,
        ctrl_i.invert_prio,
        ctrl_i.priority_cnt_numerator,
        ctrl_i.priority_cnt_denominator
      );
      $display(
        "QoS monitor: low-window share=%0.2f%% (logical low branch = %s)",
        low_window_share_pct,
        low_branch_str
      );
      $display("QoS monitor: PASS");
    end
  end

endmodule
