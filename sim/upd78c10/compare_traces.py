#!/usr/bin/env python3
"""Compare the golden model's trace with the RTL's: lines must be identical (instruction states and board events) up to the end of the shorter one."""
import sys
a = open(sys.argv[1]).read().split('\n')
b = open(sys.argv[2]).read().split('\n')
a = [x.lower() for x in a if x]
b = [x.lower() for x in b if x]
n = min(len(a), len(b))
instr = 0
for i in range(n):
    if a[i] != b[i]:
        print('FIRST DIFFERENCE at line %d (instruction %d)' % (i + 1, instr))
        for k in range(max(0, i - 3), min(n, i + 3)):
            print('  %s model: %s' % ('>>' if k == i else '  ', a[k]))
            print('  %s rtl  : %s' % ('>>' if k == i else '  ', b[k]))
        print('  fields: T PC OP A V EA BC DE HL SP PSW IFF IRR')
        sys.exit(1)
    if not a[i].startswith('e'): instr += 1
print('IDENTICAL: %d lines (%d instructions); model has %d lines, rtl %d' % (n, instr, len(a), len(b)))
