#!/usr/bin/env python3
"""Create a simulation UART register overlay with an always-ready transmitter."""

from pathlib import Path
import argparse


THRE_ORIGINAL = """  else if(uart_thr_wen)
  begin
    uart_lsr_thre <= 1'b0;
  end"""
THRE_FAST = """  else if(uart_thr_wen)
  begin
    // The testbench captures the APB/AXI write directly.  Keeping THRE set
    // removes baud-rate wall time without changing the software interface.
    uart_lsr_thre <= 1'b1;
  end"""
TEMT_ORIGINAL = "assign uart_lsr_temt = ctrl_reg_thsr_empty && uart_lsr_thre;"
TEMT_FAST = "assign uart_lsr_temt = 1'b1; // simulation stdout sink is immediate"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    source = args.input.read_text()
    if source.count(THRE_ORIGINAL) != 1 or source.count(TEMT_ORIGINAL) != 1:
        raise SystemExit("unsupported upstream UART register implementation")
    generated = source.replace(THRE_ORIGINAL, THRE_FAST, 1)
    generated = generated.replace(TEMT_ORIGINAL, TEMT_FAST, 1)
    args.output.write_text(generated)
    print("[rtl-image] simulation UART transmitter wait disabled")


if __name__ == "__main__":
    main()
