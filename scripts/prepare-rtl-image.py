#!/usr/bin/env python3
"""Convert a flat 16 MiB image into the 32 byte-lane RAM files used by smart_run."""

from pathlib import Path
import argparse
import re


RAM_SIZE = 16 * 1024 * 1024
BANK_SIZE = 8 * 1024 * 1024
LANES = 16
DIAG_HEADER = Path(__file__).resolve().parent.parent / "platform/diagnostics/linuxcpu_diag.h"
DIAG = {name: int(value, 16) for name, value in re.findall(
    r"^#define LINUXCPU_DIAG_(\w+)\s+(0x[0-9a-fA-F]+)$",
    DIAG_HEADER.read_text(), re.MULTILINE)}


def diag_qword(offset: int) -> str:
    address = DIAG["BASE"] + offset
    memory = "`RTL_MEM" if address < BANK_SIZE else "`RTL_MEM2"
    row = (address % BANK_SIZE) // LANES
    first_lane = address % LANES
    lanes = range(first_lane + 7, first_lane - 1, -1)
    bytes_ = ", ".join(f"{memory}.ram{lane}.mem[20'h{row:05x}]" for lane in lanes)
    return "{" + bytes_ + "}"


def diagnostic_monitor() -> list[str]:
    records = {
        "trap": ["rc", "cause", "tval", "tval2", "tinst", "mepc", "mstatus", "ra", "sp"],
        "hang": ["ra", "sp", "mcause", "mepc", "mtval", "mstatus"],
        "early": ["mcause", "mepc", "mtval", "mstatus", "ra", "sp"],
    }
    lines = ["// Protocol v1: only decode records whose final commit word is present.",
             "task linux_diag_csrs;", "begin"]
    for csr in ("mcause", "mepc", "mtval", "mstatus", "scause", "sepc", "stval"):
        lines.append(f'  $display("[fatal-diag] live {csr}=0x%016h", `LINUX_TRAP_CSR.{csr}_value);')
    lines += ["end", "endtask"]
    for kind, fields in records.items():
        offset = DIAG[f"{kind.upper()}_OFFSET"]
        magic = DIAG[f"{kind.upper()}_MAGIC"]
        commit = diag_qword(offset + 8 * len(fields))
        lines += [f"wire linux_diag_{kind}_valid = ({commit} == 64'h{magic:016x});",
                  f"reg linux_diag_{kind}_seen;", f"task linux_diag_{kind};", "begin"]
        for i, field in enumerate(fields):
            lines.append(f'  $display("[fatal-diag] {kind} {field}=0x%016h", {diag_qword(offset + 8 * i)});')
        lines += ["end", "endtask"]
    lines += ["task linux_diag_watchdog;", "begin", "  linux_diag_csrs;"]
    for kind in records:
        lines += [f"  if (linux_diag_{kind}_valid) linux_diag_{kind};",
                  f'  else $display("[fatal-diag] {kind} record absent or incomplete");']
    lines += ["end", "endtask", "always @(negedge clk or negedge rst_b)", "begin",
              "  if (!rst_b || !linux_reset_seen) begin"]
    for kind in records:
        lines.append(f"    linux_diag_{kind}_seen <= 1'b0;")
    lines += ["  end else begin"]
    for kind in records:
        lines += [f"    if (linux_diag_{kind}_valid && !linux_diag_{kind}_seen) begin",
                  f"      linux_diag_{kind}_seen <= 1'b1;",
                  f'      $display("[fatal-diag] begin kind={kind} version=1 retired=%0d pc=0x%010h", linux_retired, linux_last_pc);',
                  f"      linux_diag_{kind};", "      linux_diag_csrs;",
                  f'      $display("[fatal-diag] complete kind={kind}");', "    end"]
    lines += ["  end", "end", ""]
    return lines


def replace_loader(source: str, lane_counts: list[int]) -> str:
    upstream_max_time = "`define MAX_RUN_TIME        700000000"
    linux_max_time = "`define MAX_RUN_TIME        (64'd70000000000)"
    if source.count(upstream_max_time) != 1:
        raise RuntimeError("unsupported upstream tb.v MAX_RUN_TIME setting")
    source = source.replace(upstream_max_time, linux_max_time, 1)

    # The upstream 50,000-cycle watchdog targets short bare-metal tests.  At
    # 100 MHz it expires after 0.5 ms, before Linux's normal 250 Hz timer tick.
    upstream_last_cycle = "`define LAST_CYCLE 50000"
    linux_last_cycle = "`define LAST_CYCLE 2000000"
    if source.count(upstream_last_cycle) != 1:
        raise RuntimeError("unsupported upstream tb.v LAST_CYCLE setting")
    source = source.replace(upstream_last_cycle, linux_last_cycle, 1)
    source = source.replace(
        "//check and reset retire_inst_in_period every 50000 cycles",
        "// check and reset retire_inst_in_period every LAST_CYCLE cycles",
        1,
    )

    start_marker = "integer i;\n"
    end_marker = "\n\n\n\n\n\ninitial\nbegin\n#`MAX_RUN_TIME;"
    start = source.find(start_marker)
    end = source.find(end_marker, start)
    if start < 0 or end < 0:
        raise RuntimeError("unsupported upstream tb.v loader layout")

    lines = [
        "integer linux_ram_file;",
        "integer linux_bytes_read;",
        "initial",
        "begin",
        '  $display("\\t********* Load flat Linux image *********");',
    ]
    for bank in range(2):
        memory = "`RTL_MEM" if bank == 0 else "`RTL_MEM2"
        for lane in range(LANES):
            index = bank * LANES + lane
            count = lane_counts[index]
            lines.extend([
                f'  linux_ram_file = $fopen("ram{index:02d}.bin", "rb");',
                f'  if (linux_ram_file == 0) $fatal(1, "cannot open ram{index:02d}.bin");',
                f"  linux_bytes_read = $fread({memory}.ram{lane}.mem, linux_ram_file, 0, {count});",
                "  $fclose(linux_ram_file);",
            ])
    lines.extend([
        '  $display("[linux-diag] ram[0..3]=%02h %02h %02h %02h",',
        "    `RTL_MEM.ram0.mem[0], `RTL_MEM.ram1.mem[0],",
        "    `RTL_MEM.ram2.mem[0], `RTL_MEM.ram3.mem[0]);",
        "end",
        "",
        "reg linux_reset_seen;",
        "initial linux_reset_seen = 1'b0;",
        "always @(negedge rst_b) linux_reset_seen = 1'b1;",
        "",
        "integer linux_retired;",
        "reg [39:0] linux_last_pc;",
        "always @(posedge clk or negedge rst_b)",
        "begin",
        "  if (!rst_b || !linux_reset_seen)",
        "  begin",
        "    linux_retired = 0;",
        "    linux_last_pc = 40'b0;",
        "  end",
        "  else if (`tb_retire0)",
        "  begin",
        "    linux_retired = linux_retired + 1;",
        "    linux_last_pc = `retire0_pc;",
        "    if ((linux_retired <= 32) || ((linux_retired % 10000) == 0))",
        '      $display("[linux-diag] retired=%0d pc=0x%010h cycles=%0d mhcr=0x%016h", linux_retired, `retire0_pc, $time / 10, `CPU_TOP.x_aq_top_0.x_aq_core.x_aq_cp0_top.x_aq_cp0_regs.x_aq_cp0_ext_csr.mhcr_value);',
        "  end",
        "  else if (cycle_count == 100)",
        '    $display("[linux-diag] cycle=100 reset=%b pc=0x%010h", `CPU_RST, `retire0_pc);',
        "end",
        "",
        "// Observe the UART and every bus boundary without changing their behavior.",
        "integer linux_uart_tx_count;",
        "integer linux_uart_cpu_ar_count;",
        "integer linux_uart_soc_ar_count;",
        "integer linux_uart_apb_lsr_count;",
        "integer linux_uart_axi_r_count;",
        "integer linux_uart_wait_start;",
        "integer linux_uart_wait_clocks;",
        "reg linux_uart_wait_active;",
        "reg linux_uart_hw_recovered_seen;",
        "reg [39:0] linux_uart_last_cpu_araddr;",
        "reg [39:0] linux_uart_last_soc_araddr;",
        "reg [127:0] linux_uart_last_rdata;",
        "initial",
        "begin",
        "  linux_uart_tx_count = 0;",
        "  linux_uart_cpu_ar_count = 0;",
        "  linux_uart_soc_ar_count = 0;",
        "  linux_uart_apb_lsr_count = 0;",
        "  linux_uart_axi_r_count = 0;",
        "  linux_uart_wait_start = 0;",
        "  linux_uart_wait_clocks = 0;",
        "  linux_uart_wait_active = 1'b0;",
        "  linux_uart_hw_recovered_seen = 1'b0;",
        "  linux_uart_last_cpu_araddr = 40'b0;",
        "  linux_uart_last_soc_araddr = 40'b0;",
        "  linux_uart_last_rdata = 128'b0;",
        "end",
        "always @(posedge clk or negedge rst_b)",
        "begin",
        "  if (!rst_b)",
        "  begin",
        "    linux_uart_wait_active = 1'b0;",
        "    linux_uart_hw_recovered_seen = 1'b0;",
        "    linux_uart_cpu_ar_count = 0;",
        "    linux_uart_soc_ar_count = 0;",
        "    linux_uart_apb_lsr_count = 0;",
        "    linux_uart_axi_r_count = 0;",
        "    linux_uart_wait_clocks = 0;",
        "  end",
        "  else",
        "  begin",
        "    if (`SOC_TOP.x_apb.x_uart.x_uart_apb_reg.uart_thr_wen)",
        "    begin",
        "      linux_uart_tx_count = linux_uart_tx_count + 1;",
        "      linux_uart_wait_active = 1'b1;",
        "      linux_uart_hw_recovered_seen = 1'b0;",
        "      linux_uart_wait_start = linux_retired;",
        "      linux_uart_cpu_ar_count = 0;",
        "      linux_uart_soc_ar_count = 0;",
        "      linux_uart_apb_lsr_count = 0;",
        "      linux_uart_axi_r_count = 0;",
        "      linux_uart_wait_clocks = 0;",
        '      $display("[uart-diag] THR write #%0d retired=%0d data=%02h divisor=%04h lcr=%02h thre=%b temt=%b",',
        "        linux_uart_tx_count, linux_retired,",
        "        `SOC_TOP.x_apb.apb_xx_pwdata[7:0],",
        "        `SOC_TOP.x_apb.x_uart.ctrl_baud_gen_divisor,",
        "        {`SOC_TOP.x_apb.x_uart.x_uart_apb_reg.uart_lcr_dlab, 2'b0,",
        "         `SOC_TOP.x_apb.x_uart.x_uart_apb_reg.uart_lcr},",
        "        `SOC_TOP.x_apb.x_uart.x_uart_apb_reg.uart_lsr_thre,",
        "        `SOC_TOP.x_apb.x_uart.x_uart_apb_reg.uart_lsr_temt);",
        "    end",
        "",
        "    if (linux_uart_wait_active && `SOC_TOP.biu_pad_arvalid &&",
        "        `SOC_TOP.fifo_biu_arready &&",
        "        (`SOC_TOP.biu_pad_araddr[39:12] == 28'h10015))",
        "    begin",
        "      linux_uart_cpu_ar_count = linux_uart_cpu_ar_count + 1;",
        "      linux_uart_last_cpu_araddr = `SOC_TOP.biu_pad_araddr;",
        "      if (linux_uart_cpu_ar_count <= 4)",
        '        $display("[uart-diag] CPU AR #%0d addr=%010h size=%0d len=%0d cache=%x",',
        "          linux_uart_cpu_ar_count, `SOC_TOP.biu_pad_araddr,",
        "          `SOC_TOP.biu_pad_arsize, `SOC_TOP.biu_pad_arlen,",
        "          `SOC_TOP.biu_pad_arcache);",
        "    end",
        "",
        "    if (linux_uart_wait_active && `SOC_TOP.fifo_pad_arvalid &&",
        "        `SOC_TOP.pad_biu_arready &&",
        "        (`SOC_TOP.fifo_pad_araddr[39:12] == 28'h10015))",
        "    begin",
        "      linux_uart_soc_ar_count = linux_uart_soc_ar_count + 1;",
        "      linux_uart_last_soc_araddr = `SOC_TOP.fifo_pad_araddr;",
        "      if (linux_uart_soc_ar_count <= 4)",
        '        $display("[uart-diag] SoC AR #%0d addr=%010h size=%0d len=%0d cache=%x",',
        "          linux_uart_soc_ar_count, `SOC_TOP.fifo_pad_araddr,",
        "          `SOC_TOP.fifo_pad_arsize, `SOC_TOP.fifo_pad_arlen,",
        "          `SOC_TOP.fifo_pad_arcache);",
        "    end",
        "",
        "    if (linux_uart_wait_active && `SOC_TOP.x_apb.x_uart.x_uart_apb_reg.ahb_lsr_read_vld)",
        "    begin",
        "      linux_uart_apb_lsr_count = linux_uart_apb_lsr_count + 1;",
        "      if (linux_uart_apb_lsr_count <= 4)",
        '        $display("[uart-diag] APB LSR #%0d value=%02h thre=%b temt=%b trans_en=%b empty=%b state=%05b",',
        "          linux_uart_apb_lsr_count, `SOC_TOP.x_apb.uart_apb_prdata[7:0],",
        "          `SOC_TOP.x_apb.x_uart.x_uart_apb_reg.uart_lsr_thre,",
        "          `SOC_TOP.x_apb.x_uart.x_uart_apb_reg.uart_lsr_temt,",
        "          `SOC_TOP.x_apb.x_uart.trans_clk_en,",
        "          `SOC_TOP.x_apb.x_uart.x_uart_trans.thsr_empty,",
        "          `SOC_TOP.x_apb.x_uart.x_uart_trans.cur_state);",
        "    end",
        "",
        "    if (linux_uart_wait_active && `SOC_TOP.rvalid_s2 && `SOC_TOP.rready_s2)",
        "    begin",
        "      linux_uart_axi_r_count = linux_uart_axi_r_count + 1;",
        "      linux_uart_last_rdata = `SOC_TOP.rdata_s2;",
        "      if (linux_uart_axi_r_count <= 4)",
        '        $display("[uart-diag] AXI R #%0d data=%032h",',
        "          linux_uart_axi_r_count, `SOC_TOP.rdata_s2);",
        "    end",
        "",
        "    if (linux_uart_wait_active)",
        "      linux_uart_wait_clocks = linux_uart_wait_clocks + 1;",
        "",
        "    if (linux_uart_wait_active && !linux_uart_hw_recovered_seen &&",
        "        (linux_uart_wait_clocks > 1) &&",
        "        `SOC_TOP.x_apb.x_uart.x_uart_apb_reg.uart_lsr_thre &&",
        "        `SOC_TOP.x_apb.x_uart.x_uart_apb_reg.uart_lsr_temt)",
        "    begin",
        '      $display("[uart-diag] HW TX recovered after retired=%0d cpu_ar=%0d soc_ar=%0d apb_lsr=%0d axi_r=%0d",',
        "        linux_retired - linux_uart_wait_start, linux_uart_cpu_ar_count,",
        "        linux_uart_soc_ar_count, linux_uart_apb_lsr_count,",
        "        linux_uart_axi_r_count);",
        "      linux_uart_hw_recovered_seen = 1'b1;",
        "    end",
        "",
        "    if (linux_uart_wait_active && `tb_retire0 &&",
        "        ((linux_retired - linux_uart_wait_start) != 0) &&",
        "        (((linux_retired - linux_uart_wait_start) % 100000) == 0))",
        "    begin",
        '      $display("[uart-diag] WAIT retired=%0d pc=%010h cpu_ar=%0d soc_ar=%0d apb_lsr=%0d axi_r=%0d last_cpu=%010h last_soc=%010h last_rdata=%032h",',
        "        linux_retired - linux_uart_wait_start, `retire0_pc,",
        "        linux_uart_cpu_ar_count, linux_uart_soc_ar_count,",
        "        linux_uart_apb_lsr_count, linux_uart_axi_r_count,",
        "        linux_uart_last_cpu_araddr, linux_uart_last_soc_araddr,",
        "        linux_uart_last_rdata);",
        '      $display("[uart-diag] STATE divisor=%04h dll=%02h dlh=%02h lcr=%02h thre=%b temt=%b trans_en=%b empty=%b state=%05b",',
        "        `SOC_TOP.x_apb.x_uart.ctrl_baud_gen_divisor,",
        "        `SOC_TOP.x_apb.x_uart.x_uart_apb_reg.uart_dll,",
        "        `SOC_TOP.x_apb.x_uart.x_uart_apb_reg.uart_dlh,",
        "        {`SOC_TOP.x_apb.x_uart.x_uart_apb_reg.uart_lcr_dlab, 2'b0,",
        "         `SOC_TOP.x_apb.x_uart.x_uart_apb_reg.uart_lcr},",
        "        `SOC_TOP.x_apb.x_uart.x_uart_apb_reg.uart_lsr_thre,",
        "        `SOC_TOP.x_apb.x_uart.x_uart_apb_reg.uart_lsr_temt,",
        "        `SOC_TOP.x_apb.x_uart.trans_clk_en,",
        "        `SOC_TOP.x_apb.x_uart.x_uart_trans.thsr_empty,",
        "        `SOC_TOP.x_apb.x_uart.x_uart_trans.cur_state);",
        "    end",
        "  end",
        "end",
        "",
        "// Linux timer diagnostics.  These observe the integrated CLINT and",
        "// architectural pending bits without changing either implementation.",
        "`define LINUX_CLINT `CPU_TOP.x_clint_top.x_clint_func",
        "`define LINUX_TRAP_CSR `CPU_TOP.x_aq_top_0.x_aq_core.x_aq_cp0_top.x_aq_cp0_regs.x_aq_cp0_trap_csr",
        "integer linux_timer_cmp_update_count;",
        "integer linux_timer_mtip_edge_count;",
        "integer linux_timer_stip_edge_count;",
        "reg [63:0] linux_timer_prev_cmp;",
        "reg linux_timer_prev_mtip;",
        "reg linux_timer_prev_stip;",
        "initial",
        "begin",
        "  linux_timer_cmp_update_count = 0;",
        "  linux_timer_mtip_edge_count = 0;",
        "  linux_timer_stip_edge_count = 0;",
        "  linux_timer_prev_cmp = 64'hffffffffffffffff;",
        "  linux_timer_prev_mtip = 1'b0;",
        "  linux_timer_prev_stip = 1'b0;",
        "end",
        "always @(posedge clk or negedge rst_b)",
        "begin",
        "  if (!rst_b || !linux_reset_seen)",
        "  begin",
        "    linux_timer_cmp_update_count = 0;",
        "    linux_timer_mtip_edge_count = 0;",
        "    linux_timer_stip_edge_count = 0;",
        "    linux_timer_prev_cmp = 64'hffffffffffffffff;",
        "    linux_timer_prev_mtip = 1'b0;",
        "    linux_timer_prev_stip = 1'b0;",
        "  end",
        "  else",
        "  begin",
        "    if (linux_timer_prev_cmp != {`LINUX_CLINT.mtimecmph0_reg, `LINUX_CLINT.mtimecmp0_reg})",
        "    begin",
        "      linux_timer_cmp_update_count = linux_timer_cmp_update_count + 1;",
        "      if ((linux_timer_cmp_update_count <= 8) || ((linux_timer_cmp_update_count % 1000) == 0))",
        '        $display("[timer-diag] mtimecmp update #%0d mtime=0x%016h cmp=0x%016h delta=0x%016h",',
        "          linux_timer_cmp_update_count, `LINUX_CLINT.clint_mtime_reg,",
        "          {`LINUX_CLINT.mtimecmph0_reg, `LINUX_CLINT.mtimecmp0_reg},",
        "          {`LINUX_CLINT.mtimecmph0_reg, `LINUX_CLINT.mtimecmp0_reg} - `LINUX_CLINT.clint_mtime_reg);",
        "    end",
        "    if (linux_timer_prev_mtip != `LINUX_CLINT.clint_core0_mt_int)",
        "    begin",
        "      linux_timer_mtip_edge_count = linux_timer_mtip_edge_count + 1;",
        "      if ((linux_timer_mtip_edge_count <= 8) || ((linux_timer_mtip_edge_count % 1000) == 0))",
        '        $display("[timer-diag] MTIP edge #%0d value=%b mtime=0x%016h cmp=0x%016h",',
        "          linux_timer_mtip_edge_count, `LINUX_CLINT.clint_core0_mt_int,",
        "          `LINUX_CLINT.clint_mtime_reg,",
        "          {`LINUX_CLINT.mtimecmph0_reg, `LINUX_CLINT.mtimecmp0_reg});",
        "    end",
        "    if (linux_timer_prev_stip != `LINUX_TRAP_CSR.mip_value[5])",
        "    begin",
        "      linux_timer_stip_edge_count = linux_timer_stip_edge_count + 1;",
        "      if ((linux_timer_stip_edge_count <= 8) || ((linux_timer_stip_edge_count % 1000) == 0))",
        '        $display("[timer-diag] STIP edge #%0d value=%b mtime=0x%016h mip=0x%016h mie=0x%016h priv=%02b",',
        "          linux_timer_stip_edge_count, `LINUX_TRAP_CSR.mip_value[5],",
        "          `LINUX_CLINT.clint_mtime_reg, `LINUX_TRAP_CSR.mip_value,",
        "          `LINUX_TRAP_CSR.mie_value, `LINUX_TRAP_CSR.cp0_yy_priv_mode);",
        "    end",
        "    linux_timer_prev_cmp = {`LINUX_CLINT.mtimecmph0_reg, `LINUX_CLINT.mtimecmp0_reg};",
        "    linux_timer_prev_mtip = `LINUX_CLINT.clint_core0_mt_int;",
        "    linux_timer_prev_stip = `LINUX_TRAP_CSR.mip_value[5];",
        "  end",
        "end",
        "",
    ])
    lines.extend(diagnostic_monitor())
    generated = source[:start] + "\n".join(lines) + source[end:]
    watchdog_reset = "if(!rst_b) //reset to zero\n    retire_inst_in_period[31:0] <= 32'b0;"
    portable_reset = (
        "if(!rst_b || !linux_reset_seen) // wait for an actual reset assertion\n"
        "    retire_inst_in_period[31:0] <= 32'b0;"
    )
    if watchdog_reset not in generated:
        raise RuntimeError("unsupported upstream tb.v watchdog layout")
    generated = generated.replace(watchdog_reset, portable_reset, 1)
    watchdog_message = (
        '      $display("* Error: There is no instructions retired in the last %d cycles! *", '
        "`LAST_CYCLE);"
    )
    watchdog_diagnostic = (
        watchdog_message
        + "\n"
        + '      $display("[linux-diag] stalled after pc=0x%010h araddr=0x%010h arvalid=%b '
        'awaddr=0x%010h awvalid=%b", linux_last_pc, `SOC_TOP.biu_pad_araddr, '
        '`SOC_TOP.biu_pad_arvalid, `SOC_TOP.biu_pad_awaddr, `SOC_TOP.biu_pad_awvalid);'
        + "\n"
        + '      $display("[timer-diag] watchdog mtime=0x%016h cmp=0x%016h delta=0x%016h '
        'mtip=%b stip=%b mie=0x%016h mideleg=0x%016h priv=%02b updates=%0d mt_edges=%0d st_edges=%0d", '
        '`LINUX_CLINT.clint_mtime_reg, {`LINUX_CLINT.mtimecmph0_reg, `LINUX_CLINT.mtimecmp0_reg}, '
        '{`LINUX_CLINT.mtimecmph0_reg, `LINUX_CLINT.mtimecmp0_reg} - `LINUX_CLINT.clint_mtime_reg, '
        '`LINUX_CLINT.clint_core0_mt_int, `LINUX_TRAP_CSR.mip_value[5], '
        '`LINUX_TRAP_CSR.mie_value, `LINUX_TRAP_CSR.mideleg_value, '
        '`LINUX_TRAP_CSR.cp0_yy_priv_mode, linux_timer_cmp_update_count, '
        'linux_timer_mtip_edge_count, linux_timer_stip_edge_count);'
        + "\n"
        + "      linux_diag_watchdog;"
    )
    if generated.count(watchdog_message) != 1:
        raise RuntimeError("unsupported upstream tb.v watchdog message")
    return generated.replace(watchdog_message, watchdog_diagnostic, 1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--tb", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    blob = args.image.read_bytes()
    if len(blob) > DIAG["BASE"]:
        raise SystemExit(f"image is {len(blob)} bytes; overlaps reserved diagnostics at {DIAG['BASE']:#x}")

    args.output.mkdir(parents=True, exist_ok=True)
    for obsolete in args.output.glob("ram*.hex"):
        obsolete.unlink()
    for obsolete in args.output.glob("ram*.bin"):
        obsolete.unlink()
    # Fixed loader lengths let one model compare differently sized firmware.
    padded = blob + bytes(RAM_SIZE - len(blob))

    lane_counts = []
    for bank in range(2):
        bank_data = padded[bank * BANK_SIZE : (bank + 1) * BANK_SIZE]
        for lane in range(LANES):
            values = bank_data[lane::LANES]
            # readmemh warns on empty input; one zero leaves unused RAM otherwise untouched.
            if not values:
                values = b"\0"
            lane_counts.append(len(values))
            path = args.output / f"ram{bank * LANES + lane:02d}.bin"
            path.write_bytes(values)

    original_tb = args.tb.read_text()
    generated_tb = replace_loader(original_tb, lane_counts)
    (args.output / "tb-linux.v").write_text(generated_tb)
    (args.output / "firmware.size").write_text(f"{len(blob)}\n")
    print(f"[rtl-image] {len(blob)} bytes split across 32 RAM lane files")


if __name__ == "__main__":
    main()
