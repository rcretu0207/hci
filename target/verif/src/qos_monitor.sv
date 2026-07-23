/**
 * HCI branch-arbitration QoS monitor
 *
 * Observes the wide-vs-narrow branch selected on each conflict cycle, checks
 * the post-arbiter bank output, and verifies the configured service ratio over
 * all completed conflict windows in aggregate, without constraining service
 * order. It also checks conflict-free pass-through.
 */

module qos_monitor
  import hci_package::*;
  import tb_hci_pkg::*;
#(
  parameter int unsigned N_BANKS = 16
) (
  input logic                   clk_i,
  input logic                   rst_ni,
  input hci_interconnect_ctrl_t ctrl_i,
  hci_core_intf.monitor         narrow_bank_if [0:N_BANKS-1],
  hci_core_intf.monitor         wide_bank_if [0:N_BANKS-1],
  hci_core_intf.monitor         mem_bank_if [0:N_BANKS-1]
);

  typedef struct packed {
    logic                      req;
    logic                      gnt;
    logic [ADDR_WIDTH-1:0]     add;
    logic                      wen;
    logic [DATA_WIDTH-1:0]     data;
    logic [DATA_WIDTH/8-1:0]   be;
  } bank_request_t;

  int unsigned conflict_cycles_q;
  int unsigned high_conflict_cycles_q;
  int unsigned low_conflict_cycles_q;
  int unsigned ambiguous_conflict_cycles_q;
  bit failure_seen_q;
  bank_request_t narrow_request[N_BANKS];
  bank_request_t wide_request[N_BANKS];
  bank_request_t mem_request[N_BANKS];

  generate
    for (genvar ii = 0; ii < N_BANKS; ii++) begin : gen_bind
      assign narrow_request[ii].req = narrow_bank_if[ii].req;
      assign narrow_request[ii].gnt = narrow_bank_if[ii].gnt;
      assign narrow_request[ii].add = narrow_bank_if[ii].add;
      assign narrow_request[ii].wen = narrow_bank_if[ii].wen;
      assign narrow_request[ii].data = narrow_bank_if[ii].data;
      assign narrow_request[ii].be = narrow_bank_if[ii].be;
      assign wide_request[ii].req = wide_bank_if[ii].req;
      assign wide_request[ii].gnt = wide_bank_if[ii].gnt;
      assign wide_request[ii].add = wide_bank_if[ii].add;
      assign wide_request[ii].wen = wide_bank_if[ii].wen;
      assign wide_request[ii].data = wide_bank_if[ii].data;
      assign wide_request[ii].be = wide_bank_if[ii].be;
      assign mem_request[ii].req = mem_bank_if[ii].req;
      assign mem_request[ii].gnt = mem_bank_if[ii].gnt;
      assign mem_request[ii].add = mem_bank_if[ii].add;
      assign mem_request[ii].wen = mem_bank_if[ii].wen;
      assign mem_request[ii].data = mem_bank_if[ii].data;
      assign mem_request[ii].be = mem_bank_if[ii].be;
    end
  endgenerate

  function automatic bank_request_t get_branch_request(
    input int unsigned bank_idx_i,
    input bit          high_priority_i
  );
    bank_request_t ret;
    bit use_wide;

    use_wide = high_priority_i ? ctrl_i.invert_prio : !ctrl_i.invert_prio;
    if (use_wide) begin
      ret = wide_request[bank_idx_i];
    end else begin
      ret = narrow_request[bank_idx_i];
    end
    return ret;
  endfunction

  function automatic bit output_matches_source(
    input int unsigned   bank_idx_i,
    input bank_request_t source_i
  );
    if (source_i.req === 1'b1) begin
      return mem_request[bank_idx_i].req === 1'b1
          && mem_request[bank_idx_i].add === source_i.add
          && mem_request[bank_idx_i].wen === source_i.wen
          && mem_request[bank_idx_i].data === source_i.data
          && mem_request[bank_idx_i].be === source_i.be;
    end
    if (source_i.req === 1'b0) begin
      return mem_request[bank_idx_i].req === 1'b0;
    end
    return 1'b0;
  endfunction

  task automatic check_output_source(
    input int unsigned   bank_idx_i,
    input bank_request_t expected_i
  );
    if (!output_matches_source(bank_idx_i, expected_i)) begin
      failure_seen_q = 1'b1;
      $fatal(
        1,
        "QoS mismatch on bank %0d: post-arbiter interface did not match the expected source.",
        bank_idx_i
      );
    end
  endtask

  always @(posedge clk_i or negedge rst_ni) begin
    bit any_conflict;
    bit selected_high;
    bit selection_found;
    bit high_selection_matches;
    bit low_selection_matches;
    bank_request_t high_request;
    bank_request_t low_request;
    bank_request_t expected_request;
    if (!rst_ni) begin
      conflict_cycles_q = '0;
      high_conflict_cycles_q = '0;
      low_conflict_cycles_q = '0;
      ambiguous_conflict_cycles_q = '0;
      failure_seen_q = 1'b0;
    end else begin
      if ($isunknown({
            ctrl_i.invert_prio,
            ctrl_i.priority_cnt_numerator,
            ctrl_i.priority_cnt_denominator
          })
          || ctrl_i.priority_cnt_denominator == 0
          || ctrl_i.priority_cnt_numerator > ctrl_i.priority_cnt_denominator) begin
        failure_seen_q = 1'b1;
        $fatal(
          1,
          "Invalid QoS service window: invert=%0b numerator=%0d denominator=%0d.",
          ctrl_i.invert_prio,
          ctrl_i.priority_cnt_numerator,
          ctrl_i.priority_cnt_denominator
        );
      end

      any_conflict = 1'b0;
      for (int ii = 0; ii < N_BANKS; ii++) begin
        if (narrow_request[ii].req && wide_request[ii].req) begin
          any_conflict = 1'b1;
        end
      end

      if (any_conflict) begin
        selected_high = 1'b0;
        selection_found = 1'b0;
        high_selection_matches = 1'b1;
        low_selection_matches = 1'b1;

        // Check whether the complete output vector is consistent with a global
        // high-branch or low-branch selection.
        for (int ii = 0; ii < N_BANKS; ii++) begin
          high_request = get_branch_request(ii, 1'b1);
          low_request = get_branch_request(ii, 1'b0);
          expected_request = high_request.req ? high_request : low_request;
          if (!output_matches_source(ii, expected_request)) begin
            high_selection_matches = 1'b0;
          end
          if (!output_matches_source(ii, low_request)) begin
            low_selection_matches = 1'b0;
          end
        end

        if (!high_selection_matches && !low_selection_matches) begin
          failure_seen_q = 1'b1;
          $fatal(1, "QoS mismatch: bank outputs matched neither global branch selection.");
        end else if (high_selection_matches && !low_selection_matches) begin
          selected_high = 1'b1;
          selection_found = 1'b1;
        end else if (!high_selection_matches && low_selection_matches) begin
          selected_high = 1'b0;
          selection_found = 1'b1;
        end

        // If request fields are indistinguishable, grants can still reveal the
        // selected branch on a bank that accepted the request.
        for (int ii = 0; ii < N_BANKS; ii++) begin
          bit grant_identifies_selection;
          bit grant_selected_high;

          high_request = get_branch_request(ii, 1'b1);
          low_request = get_branch_request(ii, 1'b0);
          grant_identifies_selection = 1'b0;
          grant_selected_high = 1'b0;
          if (high_request.req && low_request.req) begin
            if (high_request.gnt === 1'b1 && low_request.gnt === 1'b0) begin
              grant_identifies_selection = 1'b1;
              grant_selected_high = 1'b1;
            end else if (high_request.gnt === 1'b0 && low_request.gnt === 1'b1) begin
              grant_identifies_selection = 1'b1;
              grant_selected_high = 1'b0;
            end

            if (grant_identifies_selection) begin
              if (!selection_found) begin
                selected_high = grant_selected_high;
                selection_found = 1'b1;
              end else if (selected_high != grant_selected_high) begin
                failure_seen_q = 1'b1;
                $fatal(1, "QoS mismatch: contested banks selected different branches.");
              end
            end
          end

          if (selection_found && RANDOM_GNT == 0
              && high_request.req && low_request.req) begin
            if (selected_high
                && (high_request.gnt !== 1'b1 || low_request.gnt !== 1'b0)) begin
              failure_seen_q = 1'b1;
              $fatal(1, "QoS grant mismatch on bank %0d: expected high branch.", ii);
            end else if (!selected_high
                && (high_request.gnt !== 1'b0 || low_request.gnt !== 1'b1)) begin
              failure_seen_q = 1'b1;
              $fatal(1, "QoS grant mismatch on bank %0d: expected low branch.", ii);
            end
          end
        end

        conflict_cycles_q = conflict_cycles_q + 1;
        if (!selection_found) begin
          ambiguous_conflict_cycles_q = ambiguous_conflict_cycles_q + 1;
        end else if (selected_high) begin
          high_conflict_cycles_q = high_conflict_cycles_q + 1;
        end else begin
          low_conflict_cycles_q = low_conflict_cycles_q + 1;
        end

      end else begin
        // With no narrow-wide conflict, whichever branch requests a bank passes through.
        for (int ii = 0; ii < N_BANKS; ii++) begin
          high_request = get_branch_request(ii, 1'b1);
          low_request = get_branch_request(ii, 1'b0);
          expected_request = high_request.req ? high_request : low_request;
          check_output_source(ii, expected_request);
        end
      end
    end
  end

  final begin
    real high_share_pct;
    string high_branch;
    bit ratio_inconclusive;
    int unsigned complete_windows;
    int unsigned partial_window_cycles;
    longint unsigned target_product;
    longint unsigned minimum_high_cycles;
    longint unsigned maximum_high_cycles;
    longint unsigned possible_high_minimum;
    longint unsigned possible_high_maximum;

    ratio_inconclusive = 1'b0;
    target_product = 0;
    if (ctrl_i.priority_cnt_denominator == 0) begin
      complete_windows = 0;
      partial_window_cycles = 0;
      minimum_high_cycles = 0;
      maximum_high_cycles = 0;
    end else if (ctrl_i.priority_cnt_numerator == 0) begin
      complete_windows = conflict_cycles_q / ctrl_i.priority_cnt_denominator;
      partial_window_cycles = conflict_cycles_q % ctrl_i.priority_cnt_denominator;
      minimum_high_cycles = conflict_cycles_q;
      maximum_high_cycles = conflict_cycles_q;
    end else begin
      complete_windows = conflict_cycles_q / ctrl_i.priority_cnt_denominator;
      partial_window_cycles = conflict_cycles_q % ctrl_i.priority_cnt_denominator;
      target_product = longint'(conflict_cycles_q) * ctrl_i.priority_cnt_numerator;
      minimum_high_cycles = target_product / ctrl_i.priority_cnt_denominator;
      maximum_high_cycles = (target_product + ctrl_i.priority_cnt_denominator - 1)
          / ctrl_i.priority_cnt_denominator;
    end

    possible_high_minimum = high_conflict_cycles_q;
    possible_high_maximum = high_conflict_cycles_q + ambiguous_conflict_cycles_q;

    if (!failure_seen_q && complete_windows != 0
        && (possible_high_maximum < minimum_high_cycles
            || possible_high_minimum > maximum_high_cycles)) begin
      failure_seen_q = 1'b1;
      $error(
        "QoS ratio mismatch: possible high selections are %0d to %0d; expected %0d to %0d after %0d conflicts.",
        possible_high_minimum,
        possible_high_maximum,
        minimum_high_cycles,
        maximum_high_cycles,
        conflict_cycles_q
      );
    end else if (!failure_seen_q && complete_windows != 0
        && (possible_high_minimum < minimum_high_cycles
            || possible_high_maximum > maximum_high_cycles)) begin
      ratio_inconclusive = 1'b1;
    end

    if (failure_seen_q) begin
      $display("QoS monitor: FAIL");
    end else if (conflict_cycles_q == 0) begin
      $display("QoS monitor: INCONCLUSIVE (no conflict cycles observed).");
    end else if (complete_windows == 0) begin
      $display(
        "QoS monitor: INCONCLUSIVE (%0d conflicts, no complete %0d-cycle service window).",
        conflict_cycles_q,
        ctrl_i.priority_cnt_denominator
      );
    end else if (ratio_inconclusive) begin
      $display(
        "QoS monitor: INCONCLUSIVE (%0d branch selections were observationally ambiguous).",
        ambiguous_conflict_cycles_q
      );
    end else begin
      high_branch = ctrl_i.invert_prio ? "wide" : "narrow";
      $display(
        "QoS monitor: conflicts=%0d high=%0d low=%0d ambiguous=%0d complete_windows=%0d partial_window=%0d invert_prio=%0d num=%0d den=%0d",
        conflict_cycles_q,
        high_conflict_cycles_q,
        low_conflict_cycles_q,
        ambiguous_conflict_cycles_q,
        complete_windows,
        partial_window_cycles,
        ctrl_i.invert_prio,
        ctrl_i.priority_cnt_numerator,
        ctrl_i.priority_cnt_denominator
      );
      if (ambiguous_conflict_cycles_q == 0) begin
        high_share_pct = 100.0 * real'(high_conflict_cycles_q) / real'(conflict_cycles_q);
        $display(
          "QoS monitor: observed high-priority share=%0.2f%% (logical high branch = %s)",
          high_share_pct,
          high_branch
        );
      end else begin
        $display(
          "QoS monitor: possible high selections=%0d to %0d (logical high branch = %s)",
          possible_high_minimum,
          possible_high_maximum,
          high_branch
        );
      end
      $display("QoS monitor: PASS");
    end
  end

endmodule
