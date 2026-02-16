#!/usr/bin/env python3
#
# kimi-run.py - Kimi CLI PTY Runner
# Captures full output using subprocess with real-time streaming
#
# 功能 (Features):
# - Real-time output capture
# - Timeout handling
# - Allowed tools restriction
# - Mock mode for testing (when kimi CLI not installed)
#

import argparse
import json
import os
import select
import subprocess
import sys
import time
from pathlib import Path
from datetime import datetime


class KimiRunner:
    """Kimi CLI runner with PTY support and output capture."""
    
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
        """Run Kimi CLI or mock execution."""
        self.start_time = time.time()
        
        # Check if kimi command exists
        kimi_exists = self._check_kimi_cli()
        
        if not kimi_exists:
            print("[INFO] Kimi CLI not found, switching to mock mode", file=sys.stderr)
            return self._mock_kimi_execution()
        
        return self._run_kimi_cli()
    
    def _check_kimi_cli(self):
        """Check if kimi CLI is installed."""
        try:
            result = subprocess.run(
                ['which', 'kimi'],
                capture_output=True,
                timeout=5
            )
            return result.returncode == 0
        except Exception:
            return False
    
    def _run_kimi_cli(self):
        """Run actual Kimi CLI process."""
        # Build command arguments
        cmd = ['kimi', '--print', '-p', self.prompt, '-w', str(self.workdir)]
        
        # Add allowed tools if specified
        if self.allowed_tools:
            cmd.extend(['--allowed-tools', self.allowed_tools])
        
        print(f"[Kimi] Executing: {' '.join(cmd)}", file=sys.stderr)
        
        try:
            # Start process
            process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                cwd=self.workdir,
                text=True,
                encoding='utf-8',
                errors='replace'
            )
            
            # Real-time output reading with timeout
            while True:
                # Check timeout
                elapsed = time.time() - self.start_time
                if elapsed > self.timeout:
                    print(f"\n[TIMEOUT] Task exceeded {self.timeout} seconds", file=sys.stderr)
                    process.terminate()
                    time.sleep(1)
                    if process.poll() is None:
                        process.kill()
                    return 124
                
                # Check if output available
                if process.stdout:
                    readable, _, _ = select.select([process.stdout], [], [], 0.1)
                    if readable:
                        line = process.stdout.readline()
                        if line:
                            self.output_buffer.append(line)
                            sys.stderr.write(line)
                            sys.stderr.flush()
                
                # Check if process finished
                ret = process.poll()
                if ret is not None:
                    # Read remaining output
                    remaining = process.stdout.read() if process.stdout else ""
                    if remaining:
                        self.output_buffer.append(remaining)
                        sys.stderr.write(remaining)
                        sys.stderr.flush()
                    return ret
                    
        except FileNotFoundError:
            print("[ERROR] Failed to start kimi process", file=sys.stderr)
            return self._mock_kimi_execution()
        except KeyboardInterrupt:
            print("\n[INTERRUPT] Received interrupt signal", file=sys.stderr)
            if 'process' in locals():
                process.terminate()
            return 130
        except Exception as e:
            print(f"[ERROR] Unexpected error: {e}", file=sys.stderr)
            return 1
    
    def _mock_kimi_execution(self):
        """Mock kimi execution for testing/demo purposes."""
        print(f"[Kimi Mock] Working Directory: {self.workdir}", file=sys.stderr)
        print(f"[Kimi Mock] Prompt: {self.prompt}", file=sys.stderr)
        if self.allowed_tools:
            print(f"[Kimi Mock] Allowed Tools: {self.allowed_tools}", file=sys.stderr)
        print("-" * 50, file=sys.stderr)
        
        # Simulate thinking
        print("Thinking...", file=sys.stderr)
        time.sleep(0.5)
        
        # Generate mock response based on prompt
        prompt_lower = self.prompt.lower()
        
        if "hello" in prompt_lower or "world" in prompt_lower:
            mock_output = '''\n```python
# hello_world.py
print("Hello, World!")
print("Generated by Kimi CLI")
```

This is a simple Python Hello World program.

Run with:
```bash
python hello_world.py
```
'''
        elif "analyze" in prompt_lower or "分析" in prompt_lower:
            mock_output = f'''\n## Analysis Results

**Task**: {self.prompt}
**Time**: {datetime.now().isoformat()}

### Summary
This is a mock analysis response for testing purposes.

### Key Points
1. Point A - Important finding
2. Point B - Secondary observation
3. Point C - Recommendation

### Output Files
Generated in: {self.workdir}
'''
        else:
            mock_output = f'''\n[Kimi Mock Response]

Your request: {self.prompt}

This is a simulated response from the kimi-hooks system.
In production, this would contain actual Kimi CLI output.

---
Timestamp: {datetime.now().isoformat()}
Working Directory: {self.workdir}
Allowed Tools: {self.allowed_tools or "all"}
'''
        
        print(mock_output, file=sys.stderr)
        self.output_buffer.append(mock_output)
        
        print("-" * 50, file=sys.stderr)
        print("[Kimi Mock] Task completed", file=sys.stderr)
        
        # Create a test file if directory is writable
        test_file = self.workdir / "kimi_test_output.txt"
        try:
            test_file.write_text(
                f"Kimi task completed at {datetime.now()}\n"
                f"Prompt: {self.prompt}\n"
                f"Mode: MOCK\n"
            )
            print(f"[Kimi Mock] Test file created: {test_file}", file=sys.stderr)
        except PermissionError:
            pass
        
        return 0
    
    def get_output(self):
        """Get complete output as string."""
        return ''.join(self.output_buffer)


def main():
    parser = argparse.ArgumentParser(
        description='Kimi CLI Runner - PTY wrapper with output capture'
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
