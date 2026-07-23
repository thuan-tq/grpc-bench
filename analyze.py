import re
import math
import os
import sys
import glob

def parse_results(filepath):
    if not os.path.exists(filepath):
        print(f"Warning: File not found: {filepath}")
        return None
        
    with open(filepath, 'r') as f:
        content = f.read()
    
    # Split by runs
    runs = content.split("==========================================")
    
    avg_latencies = []
    p90_latencies = []
    p99_latencies = []
    
    for run in runs:
        if not run.strip():
            continue
        
        # Search for latencies
        avg_match = re.search(r"Average Latency:\s*([\d\.]+)ms", run)
        p90_match = re.search(r"P90 Latency:\s*([\d\.]+)ms", run)
        p99_match = re.search(r"P99 Latency:\s*([\d\.]+)ms", run)
        
        if avg_match:
            avg_latencies.append(float(avg_match.group(1)))
        if p90_match:
            p90_latencies.append(float(p90_match.group(1)))
        if p99_match:
            p99_latencies.append(float(p99_match.group(1)))
            
    return avg_latencies, p90_latencies, p99_latencies

def mean(data):
    if not data:
        return 0
    return sum(data) / len(data)

def stddev(data):
    if not data:
        return 0
    m = mean(data)
    variance = sum((x - m) ** 2 for x in data) / len(data)
    return math.sqrt(variance)

def get_summary(name, avg, p90, p99):
    return {
        "name": name,
        "avg_mean": mean(avg),
        "avg_std": stddev(avg),
        "p90_mean": mean(p90),
        "p90_std": stddev(p90),
        "p99_mean": mean(p99),
        "p99_std": stddev(p99),
        "runs": len(avg)
    }

def detect_direction(filepath):
    if not os.path.exists(filepath):
        return "Unknown"
    with open(filepath, 'r') as f:
        content = f.read()
    if "[UPLOAD]" in content:
        return "UPLOAD"
    if "[DOWNLOAD]" in content:
        return "DOWNLOAD"
    return "Unknown"

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 analyze.py <results_directory>")
        sys.exit(1)
        
    results_dir = sys.argv[1]
    
    if not os.path.isdir(results_dir):
        print(f"Error: {results_dir} is not a directory")
        sys.exit(1)
        
    search_pattern = os.path.join(results_dir, "grpc_test_*_default.txt")
    files = glob.glob(search_pattern)
    
    if not files:
        print(f"No benchmark result files found in {results_dir} matching 'grpc_test_*_default.txt'")
        sys.exit(1)
        
    # Detect direction from the first file
    direction = detect_direction(files[0])
    
    summaries = {}
    
    for filepath in files:
        filename = os.path.basename(filepath)
        match = re.match(r"grpc_test_(.*)_default.txt", filename)
        if match:
            branch = match.group(1)
            label = branch.replace("alts-max-frame-size-", "Max Frame ").replace("alts-default-frame-size-", "Default Frame ")
            if branch == "master":
                label = "Master (Default 4KB)"
                
            res = parse_results(filepath)
            if res:
                avg, p90, p99 = res
                summaries[branch] = get_summary(label, avg, p90, p99)
                
    # Output Markdown
    print(f"# Benchmark Report: {os.path.basename(results_dir)}")
    print(f"- **Directory:** `{results_dir}`")
    print(f"- **Direction:** **{direction}**")
    print()
    
    print("## Summary Results")
    print("| Configuration | Runs | Average Latency | P90 Latency | P99 Latency |")
    print("| :--- | :---: | :---: | :---: | :---: |")
    
    # Print master first if exists
    if "master" in summaries:
        s = summaries["master"]
        print(f"| **{s['name']}** | {s['runs']} | {s['avg_mean']:.3f} ms (±{s['avg_std']:.3f}) | {s['p90_mean']:.3f} ms (±{s['p90_std']:.3f}) | {s['p99_mean']:.3f} ms (±{s['p99_std']:.3f}) |")
        
    for branch, s in summaries.items():
        if branch == "master":
            continue
        print(f"| {s['name']} | {s['runs']} | {s['avg_mean']:.3f} ms (±{s['avg_std']:.3f}) | {s['p90_mean']:.3f} ms (±{s['p90_std']:.3f}) | {s['p99_mean']:.3f} ms (±{s['p99_std']:.3f}) |")
    print()
    
    # Comparison vs Master
    if "master" in summaries and len(summaries) > 1:
        m = summaries["master"]
        print("## Comparison vs Master")
        print("| Configuration | Average Latency Change | P90 Latency Change | P99 Latency Change |")
        print("| :--- | :---: | :---: | :---: |")
        for branch, s in summaries.items():
            if branch == "master":
                continue
            avg_change = f"{((s['avg_mean'] - m['avg_mean']) / m['avg_mean']) * 100:.2f}%" if m["avg_mean"] else "N/A"
            p90_change = f"{((s['p90_mean'] - m['p90_mean']) / m['p90_mean']) * 100:.2f}%" if m["p90_mean"] else "N/A"
            p99_change = f"{((s['p99_mean'] - m['p99_mean']) / m['p99_mean']) * 100:.2f}%" if m["p99_mean"] else "N/A"
            print(f"| {s['name']} | {avg_change} | {p90_change} | {p99_change} |")
        print()

if __name__ == "__main__":
    main()
