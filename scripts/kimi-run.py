#!/usr/bin/env python3
#
# kimi-run.py - Kimi CLI Runner
# Captures full output with real-time streaming
#
# Features:
# - Real-time output capture via tee-style streaming
# - Timeout handling
# - Allowed tools restriction
# - Strict mode: no mock fallback — fails loudly if Kimi CLI not found
# - PTY support via script(1) for non-interactive environments
#

import argparse
import json
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path
from datetime import datetime


class KimiRunner:
    """Kimi CLI runner with output capture."""
    
    def __init__(self, prompt, workdir, timeout=3600, meta_file=None, allowed_tools=None):
        self.prompt = prompt
        self.workdir = Path(workdir).resolve()
        self.timeout = timeout
        self.meta_file = meta_file
        self.allowed_tools = allowed_tools
        self.output_buffer = []
        self.start_time = None
        
        # Ensure working directory exists
        self.workdir.mkdir(parents=True, exist_ok=True)
    
    def run(self):
        """Run Kimi CLI. Fails loudly if not installed."""
        self.start_time = time.time()
        
        # [P0 fix] Check if kimi command exists — no mock fallback
        if not self._check_kimi_cli():
            print("[FATAL] Kimi CLI not found in PATH.", file=sys.stderr)
            print("[FATAL] Install with: pip install kimi-cli && kimi login", file=sys.stderr)
            print("[FATAL] Or set KIMI_BIN environment variable to the correct path.", file=sys.stderr)
            return 127  # Standard "command not found" exit code
        
        return self._run_kimi_cli()
    
    def _check_kimi_cli(self):
        """Check if kimi CLI is installed."""
        # Check KIMI_BIN env var first
        kimi_bin = os.environ.get("KIMI_BIN", "")
        if kimi_bin and Path(kimi_bin).is_file():
            return True
        
        try:
            result = subprocess.run(
                ['which', 'kimi'],
                capture_output=True,
                timeout=5
            )
            return result.returncode == 0
        except Exception:
            return False
    
    def _get_kimi_bin(self):
        """Get kimi binary path."""
        kimi_bin = os.environ.get("KIMI_BIN", "")
        if kimi_bin and Path(kimi_bin).is_file():
            return kimi_bin
        return "kimi"
    
    def _run_kimi_cli(self):
        """Run actual Kimi CLI process with PTY support."""
        kimi_bin = self._get_kimi_bin()
        
        # Build command arguments
        cmd = [kimi_bin, '--print', '-p', self.prompt, '-w', str(self.workdir)]
        
        # Add allowed tools if specified
        if self.allowed_tools:
            cmd.extend(['--allowed-tools', self.allowed_tools])
        
        print(f"[Kimi] Executing: {' '.join(cmd)}", file=sys.stderr)
        
        # [P3] Try to use script(1) for PTY support (prevents hanging in non-TTY)
        use_script = self._check_script_available()
        
        try:
            if use_script:
                return self._run_with_script(cmd)
            else:
                return self._run_direct(cmd)
                
        except FileNotFoundError:
            print(f"[FATAL] Failed to start kimi process: {kimi_bin} not found", file=sys.stderr)
            return 127
        except KeyboardInterrupt:
            print("\n[INTERRUPT] Received interrupt signal", file=sys.stderr)
            return 130
        except Exception as e:
            print(f"[ERROR] Unexpected error: {e}", file=sys.stderr)
            return 1
    
    def _check_script_available(self):
        """Check if script(1) command is available."""
        try:
            result = subprocess.run(['which', 'script'], capture_output=True, timeout=3)
            return result.returncode == 0
        except Exception:
            return False
    
    def _run_with_script(self, cmd):
        """Run command wrapped in script(1) for PTY support."""
        cmd_str = " ".join(shlex.quote(c) for c in cmd)
        script_cmd = ['script', '-q', '-c', cmd_str, '/dev/null']
        
        print(f"[Kimi] Using script(1) for PTY support", file=sys.stderr)
        return self._run_process(script_cmd)
    
    def _run_direct(self, cmd):
        """Run command directly without PTY wrapper."""
        print(f"[Kimi] Running directly (no script(1) available)", file=sys.stderr)
        return self._run_process(cmd)
    
    def _run_process(self, cmd):
        """Run a subprocess with timeout and output capture."""
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            cwd=self.workdir,
            text=True,
            encoding='utf-8',
            errors='replace'
        )
        
        try:
            while True:
                # Check timeout
                elapsed = time.time() - self.start_time
                if elapsed > self.timeout:
                    print(f"\n[TIMEOUT] Task exceeded {self.timeout} seconds", file=sys.stderr)
                    process.terminate()
                    time.sleep(2)
                    if process.poll() is None:
                        process.kill()
                    return 124
                
                # Read output line by line
                if process.stdout:
                    line = process.stdout.readline()
                    if line:
                        self.output_buffer.append(line)
                        sys.stderr.write(line)
                        sys.stderr.flush()
                    elif process.poll() is not None:
                        # Process finished and no more output
                        break
                else:
                    if process.poll() is not None:
                        break
                    time.sleep(0.1)
            
            # Read any remaining output
            if process.stdout:
                remaining = process.stdout.read()
                if remaining:
                    self.output_buffer.append(remaining)
                    sys.stderr.write(remaining)
                    sys.stderr.flush()
            
            return process.returncode
            
        except KeyboardInterrupt:
            process.terminate()
            raise
    
    def get_output(self):
        """Get complete output as string."""
        return ''.join(self.output_buffer)


def main():
    parser = argparse.ArgumentParser(
        description='Kimi CLI Runner - Wrapper with output capture and timeout'
    )
    parser.add_argument(
        '-p', '--prompt',
        required=True,
        help='Task prompt/description'
    )
    parser.add_argument(
        '-w', '--workdir',
        default='.',
        help='Working directory (default: current directory)'
    )
    parser.add_argument(
        '-t', '--timeout',
        type=int,
        default=3600,
        help='Timeout in seconds (default: 3600)'
    )
    parser.add_argument(
        '--meta-file',
        help='Path to task metadata JSON file'
    )
    parser.add_argument(
        '--allowed-tools',
        help='Comma-separated list of allowed tools (e.g., "read,exec,write")'
    )
    
    args = parser.parse_args()
    
    # Create runner instance
    runner = KimiRunner(
        prompt=args.prompt,
        workdir=args.workdir,
        timeout=args.timeout,
        meta_file=args.meta_file,
        allowed_tools=args.allowed_tools
    )
    
    # Execute
    exit_code = runner.run()
    
    # Output result markers for parent script parsing
    output = runner.get_output()
    print("\n" + "="*50)
    print("[KIMI_OUTPUT_START]")
    print(output)
    print("[KIMI_OUTPUT_END]")
    
    return exit_code


if __name__ == '__main__':
    sys.exit(main())
