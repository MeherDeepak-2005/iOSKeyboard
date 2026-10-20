#!/usr/bin/env python3
"""Summarize measured kernel timings and macOS process peak RSS, without device extrapolation."""
import json
import re
import statistics
from pathlib import Path

root = Path(__file__).resolve().parents[2]
results = root / 'tools/evaluation/results/native-performance'
summary = {
    'date': '2026-10-06',
    'host': {'cpu': 'Apple M2', 'model': 'Mac14,2', 'ram_bytes': 8589934592},
    'physical_iphone': 'not_measured; known iPhones unavailable',
    'production_backend': 'Swift; native paths remain opt-in comparison implementations',
    'timings': {}, 'macos_peak_rss': {},
    'vocabulary_disk_bytes_unchanged': (root / 'keyboard/langdata.bin').stat().st_size,
}
for platform in ('macos', 'simulator'):
    report = json.loads((results / f'{platform}-kernels.json').read_text())
    for row in report['rows']:
        row['median_latency_reduction_percent'] = 100 * (1 - row['native_bridge_p50_ms'] / row['swift_p50_ms'])
    summary['timings'][platform] = report
for backend in ('swift', 'native'):
    rss = []
    for trial in range(1, 6):
        raw = (results / f'memory-{backend}-{trial}.txt').read_text()
        match = re.search(r'(\d+)\s+maximum resident set size', raw)
        if not match:
            raise ValueError(f'missing Darwin peak RSS for {backend} trial {trial}')
        rss.append(int(match.group(1)))
        assert json.loads((results / f'memory-{backend}-{trial}.json').read_text())['candidate_count'] == 2
    summary['macos_peak_rss'][backend] = {'samples_bytes': rss, 'median_bytes': statistics.median(rss)}
summary['macos_peak_rss']['native_minus_swift_median_bytes'] = (
    summary['macos_peak_rss']['native']['median_bytes'] - summary['macos_peak_rss']['swift']['median_bytes'])
(results / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
print(json.dumps({'simulator_speedups': {r['case']: round(r['median_speedup'], 3)
    for r in summary['timings']['simulator']['rows']}, 'peak_rss': summary['macos_peak_rss']}, indent=2))
