# -*- coding: utf-8 -*-
"""Shared v1 worker protocol. Python 2.7 (Rhino 7) and Python 3 compatible."""
import hashlib
import math
import os
import struct

APPROVED_SHA256 = 'b6a02b00a3cb35cd93976be0d070683f275c6b8e61b98c474dd75a97b3c0e376'


def approved_worker(path):
    with open(path, 'rb') as source:
        digest = hashlib.sha256(source.read()).hexdigest()
    if digest != APPROVED_SHA256:
        raise ValueError('Working EXE changed; execution refused')
    return os.path.abspath(path)


def directions(path):
    import json
    with open(path, 'r') as source:
        raw = json.load(source)
    result = []
    for v in raw:
        length = math.sqrt(sum(x*x for x in v))
        if not length or not all(not math.isnan(x) and not math.isinf(x) for x in v):
            raise ValueError('Invalid sun direction')
        result.append(tuple(x/length for x in v))
    if len(result) != 510:
        raise ValueError('Expected the original 510 directions')
    return result


def read_output(path, point_count, direction_count, inches_to_model):
    with open(path, 'rb') as source:
        data = source.read()
    expected = 16 + point_count*direction_count*8
    if len(data) != expected or data[:8] != b'CJOUT001' or struct.unpack('<II', data[8:16]) != (point_count, direction_count):
        raise ValueError('Invalid C++ response')
    values = struct.unpack('<%dd' % (point_count*direction_count), data[16:])
    if any(math.isnan(x) or math.isinf(x) or (x != -1 and x <= 0) for x in values):
        raise ValueError('Invalid C++ distance')
    return [[None if x == -1 else x*inches_to_model for x in values[i*direction_count:(i+1)*direction_count]] for i in range(point_count)]


def assess(distances):
    segments, current = [], 0
    for distance in distances:
        if distance is None:
            current += 1
        elif current:
            segments.append(current)
            current = 0
    if current:
        segments.append(current)
    total, longest = sum(segments), max(segments or [0])
    return {'passed': longest >= 90 or (len(segments) >= 2 and total >= 120 and longest >= 60),
            'total': total, 'longest': longest, 'segments': segments}
