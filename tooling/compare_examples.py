"""Compare world vertex positions and primitive counts, not topology or materials."""
import argparse
from collections import Counter, defaultdict
from itertools import product
import json
import math
from pathlib import Path


def points(data):
    result = set()
    for entity in data['entities']:
        result.update(tuple(p) for p in entity.get('endpoints_mm', []))
        for loop in entity.get('loops_mm', []):
            result.update(tuple(p) for p in loop['vertices'])
    return result


def missing(source, target, tolerance):
    buckets = defaultdict(list)
    def cell(p):
        return tuple(math.floor(v / tolerance) for v in p)
    for p in target:
        buckets[cell(p)].append(p)
    absent = []
    for p in source:
        base = cell(p)
        candidates = (q for offset in product((-1, 0, 1), repeat=3)
                      for q in buckets.get(tuple(base[i] + offset[i] for i in range(3)), ()))
        if not any(math.dist(p, q) <= tolerance for q in candidates):
            absent.append(p)
    return absent


def compare(expected, actual, tolerance=0.1):
    if not math.isfinite(tolerance) or tolerance <= 0:
        raise ValueError('Tolerance must be finite and positive')
    if expected['units'] != 'mm' or actual['units'] != 'mm':
        raise ValueError('Snapshots must use millimeters')
    if expected['summary']['truncated'] or actual['summary']['truncated']:
        raise ValueError('Cannot compare truncated captures')
    a, b = points(expected), points(actual)
    absent, extra = missing(a, b, tolerance), missing(b, a, tolerance)
    counts_a = Counter(e['type'] for e in expected['entities'])
    counts_b = Counter(e['type'] for e in actual['entities'])
    return {'passed': not absent and not extra and counts_a == counts_b,
            'scope': 'World vertex positions and primitive counts only; topology, materials and semantic behavior are not verified.',
            'tolerance_mm': tolerance, 'missing_vertices': len(absent), 'extra_vertices': len(extra),
            'expected_counts': dict(counts_a), 'actual_counts': dict(counts_b),
            'missing_examples_mm': absent[:10], 'extra_examples_mm': extra[:10]}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('expected', type=Path)
    parser.add_argument('actual', type=Path)
    parser.add_argument('--tolerance-mm', type=float, default=0.1)
    args = parser.parse_args()
    report = compare(json.loads(args.expected.read_text(encoding='utf-8')),
                     json.loads(args.actual.read_text(encoding='utf-8')), args.tolerance_mm)
    print(json.dumps(report, indent=2))
    raise SystemExit(0 if report['passed'] else 1)
