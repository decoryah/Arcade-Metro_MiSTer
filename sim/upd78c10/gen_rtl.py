#!/usr/bin/env python3
"""Translate MAME 0.289's uPD7810 instruction handlers (upd7810_opcodes.cpp, BSD-3-Clause) into SystemVerilog for rtl/upd78c10.sv.

  python gen_rtl.py      reads ref/mame/src/devices/cpu/upd7810/{upd7810_opcodes.cpp,upd7810_table.cpp},
                         writes rtl/upd78c10_ops.svh  (the instruction steps, included inside the CPU's state machine)
                                rtl/upd78c10_tab.svh  (opcode -> handler id, cycle counts, lengths, L0/L1 masks, as functions)
                                sim/upd78c10/gen_report.txt  (handlers that could not be translated)

Execution model of the generated code (see rtl/upd78c10.sv):  one instruction = a handler id `hid` and a step counter `hstep`.  A step is straight-line
code in blocking assignments (C semantics: every operand is widened to 32 bits, the result is truncated on assignment to the register or local's type);
a step ends in a bus request (opcode/operand read RDOPARG, data read RM, write WM) or in `ex_done`.  The value of a read is `rd_data` in the next step.
Handler locals live in module-level 32-bit regs `v_<name>`.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), '..', 'tools'))
import paths as T  # noqa: E402

SRC = os.path.join(T.BASE, 'ref', 'mame', 'src', 'devices', 'cpu', 'upd7810')
RTL = os.path.join(T.REPO, 'rtl')

TABLES = ['s_opXX_7810', 's_op48', 's_op4C', 's_op4D', 's_op60', 's_op64', 's_op70', 's_op74']

# ------------------------------------------------------------------------------------------------ tokenizer
TOK = re.compile(r'\s*(?:(0x[0-9A-Fa-f]+|\d+)|([A-Za-z_]\w*)|(<<=|>>=|\+\+|--|<<|>>|<=|>=|==|!=|&&|\|\||\+=|-=|\*=|/=|%=|&=|\|=|\^=|[-+*/%&|^~!<>=?:;,.(){}\[\]])|("(?:[^"\\]|\\.)*"))')


def tokenize(src):
    src = re.sub(r'//[^\n]*', '', src)
    src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
    out = []
    pos = 0
    src = src.strip()
    while pos < len(src):
        m = TOK.match(src, pos)
        if not m:
            raise SyntaxError('bad token at %r' % src[pos:pos + 20])
        pos = m.end()
        if m.group(1): out.append(('num', m.group(1)))
        elif m.group(2): out.append(('id', m.group(2)))
        elif m.group(3): out.append(('op', m.group(3)))
        else: out.append(('str', m.group(4)))
    return out


class Unsupported(Exception):
    pass


# ------------------------------------------------------------------------------------------------ parser (AST = tuples)
class Parser:
    def __init__(self, toks):
        self.t = toks
        self.i = 0

    def peek(self, k=0):
        return self.t[self.i + k] if self.i + k < len(self.t) else ('eof', '')

    def next(self):
        v = self.t[self.i]
        self.i += 1
        return v

    def accept(self, val):
        if self.peek()[1] == val and self.peek()[0] in ('op', 'id'):
            self.i += 1
            return True
        return False

    def expect(self, val):
        if not self.accept(val):
            raise SyntaxError('expected %r got %r' % (val, self.peek()))

    # statements
    def block(self):
        out = []
        while self.peek()[0] != 'eof' and self.peek()[1] != '}':
            out.append(self.stmt())
        return out

    def stmt(self):
        t = self.peek()
        if t[1] == '{':
            self.next(); b = self.block(); self.expect('}'); return ('block', b)
        if t == ('id', 'if'):
            self.next(); self.expect('('); c = self.expr(); self.expect(')')
            a = self.stmt(); b = None
            if self.accept('else'): b = self.stmt()
            return ('if', c, a, b)
        if t == ('id', 'switch'):
            self.next(); self.expect('('); e = self.expr(); self.expect(')'); self.expect('{')
            cases = []
            while self.peek()[1] != '}':
                if self.accept('case'):
                    v = self.expr(); self.expect(':'); label = [v]
                elif self.accept('default'):
                    self.expect(':'); label = ['default']
                else:
                    raise SyntaxError('switch body')
                body = []
                while self.peek()[1] not in ('case', 'default', '}'):
                    body.append(self.stmt())
                cases.append((label[0], body))
            self.expect('}')
            return ('switch', e, cases)
        if t == ('id', 'break'):
            self.next(); self.expect(';'); return ('break',)
        if t == ('id', 'return'):
            self.next(); self.expect(';'); return ('return',)
        if t[0] == 'id' and t[1] in ('uint8_t', 'uint16_t', 'uint32_t', 'int', 'int8_t', 'PAIR', 'unsigned'):
            return self.decl()
        e = self.expr(); self.expect(';')
        return ('expr', e)

    def decl(self):
        ty = self.next()[1]
        items = []
        while True:
            name = self.next()[1]
            init = None
            if self.accept('='): init = self.assign()
            items.append((name, init))
            if not self.accept(','): break
        self.expect(';')
        return ('decl', ty, items)

    # expressions (precedence climbing)
    def expr(self):
        e = self.assign()
        while self.accept(','):
            e = ('comma', e, self.assign())
        return e

    def assign(self):
        l = self.ternary()
        t = self.peek()
        if t[0] == 'op' and t[1] in ('=', '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', '<<=', '>>='):
            self.next()
            r = self.assign()
            return ('assign', t[1], l, r)
        return l

    def ternary(self):
        c = self.binary(0)
        if self.accept('?'):
            a = self.assign(); self.expect(':'); b = self.ternary()
            return ('cond', c, a, b)
        return c

    PREC = [['||'], ['&&'], ['|'], ['^'], ['&'], ['==', '!='], ['<', '<=', '>', '>='], ['<<', '>>'], ['+', '-'], ['*', '/', '%']]

    def binary(self, lvl):
        if lvl == len(self.PREC):
            return self.unary()
        l = self.binary(lvl + 1)
        while self.peek()[0] == 'op' and self.peek()[1] in self.PREC[lvl]:
            op = self.next()[1]
            r = self.binary(lvl + 1)
            l = ('bin', op, l, r)
        return l

    def unary(self):
        t = self.peek()
        if t[0] == 'op' and t[1] in ('!', '~', '-', '+'):
            self.next(); return ('un', t[1], self.unary())
        if t[0] == 'op' and t[1] in ('++', '--'):
            self.next(); return ('preinc', t[1], self.unary())
        if t[1] == '(' and self.peek(1)[0] == 'id' and self.peek(1)[1] in ('uint8_t', 'uint16_t', 'uint32_t', 'int', 'int8_t') and self.peek(2)[1] == ')':
            self.next(); ty = self.next()[1]; self.next()
            return ('cast', ty, self.unary())
        return self.postfix()

    def postfix(self):
        e = self.primary()
        while True:
            t = self.peek()
            if t[1] == '.' and t[0] == 'op':
                self.next(); e = ('member', e, self.next()[1])
            elif t[1] == '[':
                self.next(); i = self.expr(); self.expect(']'); e = ('index', e, i)
            elif t[1] == '(' and (e[0] == 'id' or (e[0] == 'member' and e[1][0] == 'id')):
                if e[0] == 'member': e = ('id', e[1][1] + '.' + e[2])
                self.next(); args = []
                if self.peek()[1] != ')':
                    args.append(self.assign())
                    while self.accept(','): args.append(self.assign())
                self.expect(')'); e = ('call', e[1], args)
            elif t[0] == 'op' and t[1] in ('++', '--'):
                self.next(); e = ('postinc', t[1], e)
            else:
                return e

    def primary(self):
        t = self.next()
        if t[0] == 'num': return ('num', int(t[1], 0))
        if t[0] == 'str': return ('str', t[1])
        if t[0] == 'id': return ('id', t[1])
        if t[1] == '(':
            e = self.expr(); self.expect(')'); return e
        raise SyntaxError('primary %r' % (t,))


# ------------------------------------------------------------------------------------------------ code generation
# register names -> (storage, msb, lsb); reads are zero-extended to 32 bits, writes truncate
REG = {
    'A': ('r_va', 7, 0), 'V': ('r_va', 15, 8), 'VA': ('r_va', 15, 0),
    'B': ('r_bc', 15, 8), 'C': ('r_bc', 7, 0), 'BC': ('r_bc', 15, 0),
    'D': ('r_de', 15, 8), 'E': ('r_de', 7, 0), 'DE': ('r_de', 15, 0),
    'H': ('r_hl', 15, 8), 'L': ('r_hl', 7, 0), 'HL': ('r_hl', 15, 0),
    'EA': ('r_ea', 15, 0), 'EAL': ('r_ea', 7, 0), 'EAH': ('r_ea', 15, 8),
    'PC': ('r_pc', 15, 0), 'PCL': ('r_pc', 7, 0), 'PCH': ('r_pc', 15, 8), 'PCD': ('r_pc', 15, 0),
    'SP': ('r_sp', 15, 0), 'SPL': ('r_sp', 7, 0), 'SPH': ('r_sp', 15, 8), 'SPD': ('r_sp', 15, 0),
    'VA2': ('r_va2', 15, 0), 'BC2': ('r_bc2', 15, 0), 'DE2': ('r_de2', 15, 0), 'HL2': ('r_hl2', 15, 0), 'EA2': ('r_ea2', 15, 0),
    'PSW': ('r_psw', 7, 0), 'OP': ('r_op', 7, 0), 'OP2': ('r_op2', 7, 0),
    'MKL': ('r_mkl', 7, 0), 'MKH': ('r_mkh', 7, 0), 'SMH': ('r_smh', 7, 0), 'SML': ('r_sml', 7, 0), 'EOM': ('r_eom', 7, 0), 'TMM': ('r_tmm', 7, 0),
    'ETMM': ('r_etmm', 7, 0), 'MA': ('r_ma', 7, 0), 'MB': ('r_mb', 7, 0), 'MC': ('r_mc', 7, 0), 'MM': ('r_mm', 7, 0), 'MF': ('r_mf', 7, 0),
    'MCC': ('r_mcc', 7, 0), 'MT': ('r_mt', 7, 0), 'ANM': ('r_anm', 7, 0), 'ZCM': ('r_zcm', 7, 0), 'RXB': ('r_rxb', 7, 0), 'TXB': ('r_txb', 7, 0),
    'TM0': ('r_tm0', 7, 0), 'TM1': ('r_tm1', 7, 0), 'ETM0': ('r_etm0', 15, 0), 'ETM1': ('r_etm1', 15, 0), 'ECNT': ('r_ecnt', 15, 0),
    'ECPT': ('r_ecpt', 15, 0), 'CNT0': ('r_cnt0', 7, 0), 'CNT1': ('r_cnt1', 7, 0), 'IRR': ('r_irr', 15, 0), 'ITF': ('r_itf', 15, 0),
    'm_va': ('r_va', 15, 0), 'm_pa_out': ('r_pa_out', 7, 0), 'm_pb_out': ('r_pb_out', 7, 0), 'm_pc_out': ('r_pc_out', 7, 0), 'm_pf_out': ('r_pf_out', 7, 0),
    'm_nmi': ('r_nmi', 0, 0),
    'IFF': ('r_iff', 0, 0), 'm_iff_pending': ('r_iff_pending', 0, 0), 'm_halt': ('r_halt', 0, 0),
}
CONST = {'CY': 0x01, 'F1': 0x02, 'L0': 0x04, 'L1': 0x08, 'HC': 0x10, 'SK': 0x20, 'Z': 0x40, 'F7': 0x80,
         'INTFNMI': 0x0001, 'INTFT0': 0x0002, 'INTFT1': 0x0004, 'INTF1': 0x0008, 'INTF2': 0x0010, 'INTFE0': 0x0020, 'INTFE1': 0x0040,
         'INTFEIN': 0x0080, 'INTFAD': 0x0100, 'INTFSR': 0x0200, 'INTFST': 0x0400, 'INTER': 0x0800, 'INTOV': 0x1000, 'INTF0': 0x2000,
         'INTAN4': 1, 'INTAN5': 2, 'INTAN6': 4, 'INTAN7': 8, 'INTSB': 0x10,
         'UPD7810_PORTA': 0, 'UPD7810_PORTB': 1, 'UPD7810_PORTC': 2, 'UPD7810_PORTD': 3, 'UPD7810_PORTF': 4, 'UPD7807_PORTT': 5, 'CLEAR_LINE': 0, 'ASSERT_LINE': 1}
TYPE_BITS = {'uint8_t': 8, 'int8_t': 8, 'uint16_t': 16, 'uint32_t': 32, 'int': 32, 'PAIR': 32, 'unsigned': 32}
SIDE_CALLS = {'write_smh': 'do_write_smh', 'upd7810_write_EOM': 'do_write_eom', 'upd7810_write_TXB': 'do_write_txb'}


class Gen:
    def __init__(self, name):
        self.name = name
        self.locals = {}          # name -> type
        self.steps = [[]]         # list of lists of code lines
        self.tmp = 0
        self.rm_vals = []
        self.pending_close = False

    # -------- emit helpers
    def emit(self, line):
        self.steps[-1].append(line)

    def new_step(self):
        if self.pending_close:
            self.emit('end')
            self.pending_close = False
        self.steps.append([])

    # -------- expressions: returns SV text of a 32-bit value
    def val(self, e):
        k = e[0]
        if k == 'num': return "32'd%d" % e[1]
        if k == 'id':
            n = e[1]
            if n in self.locals: return ('sext8(v_%s)' % n) if self.locals[n] == 'int8_t' else 'v_' + n
            if n in CONST: return "32'd%d" % CONST[n]
            if n in REG:
                s, hi, lo = REG[n]
                if hi == lo: return "{31'b0, %s}" % s
                return "{%d'b0, %s[%d:%d]}" % (32 - (hi - lo + 1), s, hi, lo)
            raise Unsupported('identifier ' + n)
        if k == 'member':
            b = e[1]
            if b[0] == 'id' and self.locals.get(b[1]) == 'PAIR':
                f = e[2]
                return "{%s}" % self.pair_slice(b[1], f)
            if b[0] == 'member' and b[1][0] == 'id' and self.locals.get(b[1][1]) == 'PAIR':
                return "{%s}" % self.pair_slice(b[1][1], b[2] + '.' + e[2])
            if b[0] == 'id' and b[1] == 'm_va':
                return {'d': "{16'b0, r_va}", 'w': "{16'b0, r_va}"}.get(e[2], None) or self.unsup('m_va.' + e[2])
            raise Unsupported('member')
        if k == 'index':
            if e[1] == ('id', 'CR') and e[2][0] == 'num': return "{24'b0, r_cr%d}" % e[2][1]
            raise Unsupported('index')
        if k == 'un':
            o = e[1]
            if o == '!': return "(%s == 32'd0 ? 32'd1 : 32'd0)" % self.val(e[2])
            if o == '~': return "(~%s)" % self.val(e[2])
            if o == '-': return "(-%s)" % self.val(e[2])
            return self.val(e[2])
        if k == 'bin':
            o, l, r = e[1], self.val(e[2]), self.val(e[3])
            if o in ('==', '!=', '<', '<=', '>', '>='): return "((%s %s %s) ? 32'd1 : 32'd0)" % (l, o, r)
            if o == '&&': return "(((%s != 32'd0) && (%s != 32'd0)) ? 32'd1 : 32'd0)" % (l, r)
            if o == '||': return "(((%s != 32'd0) || (%s != 32'd0)) ? 32'd1 : 32'd0)" % (l, r)
            if o == '>>' and self.is_signed(e[2]): return "sra32(%s, %s)" % (l, r)
            return "(%s %s %s)" % (l, o, r)
        if k == 'cond':
            return "((%s != 32'd0) ? %s : %s)" % (self.val(e[1]), self.val(e[2]), self.val(e[3]))
        if k == 'cast':
            b = TYPE_BITS[e[1]]
            v = self.val(e[2])
            if e[1] == 'int8_t': return 'sext8(%s)' % v
            return v if b == 32 else "{%d'b0, %d'(%s)}" % (32 - b, b, v)
        if k == 'call':
            n, a = e[1], e[2]
            if n == 'RM': return 'rd_data32'
            if n == 'RP': return "{24'b0, rp(%s)}" % self.val(a[0])
            if n == 'BIT': return "((%s >> %s) & 32'd1)" % (self.val(a[0]), self.val(a[1]))
            raise Unsupported('call ' + n)
        raise Unsupported('expr ' + k)

    def is_signed(self, e):
        return (e[0] == 'cast' and e[1] == 'int8_t') or (e[0] == 'id' and self.locals.get(e[1]) == 'int8_t')

    def unsup(self, what):
        raise Unsupported(what)

    def pair_slice(self, var, field):
        base = 'v_' + var
        m = {'d': '%s[31:0]', 'w.l': '%s[15:0]', 'w.h': '%s[31:16]', 'b.l': '%s[7:0]', 'b.h': '%s[15:8]'}[field]
        w = {'d': 32, 'w.l': 16, 'w.h': 16, 'b.l': 8, 'b.h': 8}[field]
        return ("%d'b0, " % (32 - w) if w < 32 else '') + m % base

    # -------- lvalues: returns (SV lvalue text, width) for a blocking assignment of a truncated value
    def lval(self, e):
        k = e[0]
        if k == 'id':
            n = e[1]
            if n in self.locals:
                return 'v_' + n, TYPE_BITS[self.locals[n]]
            if n in REG:
                s, hi, lo = REG[n]
                if hi == lo: return s, 1
                return '%s[%d:%d]' % (s, hi, lo), hi - lo + 1
            raise Unsupported('lvalue ' + n)
        if k == 'member':
            b = e[1]
            if b[0] == 'id' and self.locals.get(b[1]) == 'PAIR':
                f = e[2]
                w = {'d': 32, 'w.l': 16, 'w.h': 16, 'b.l': 8, 'b.h': 8}[f]
                return {'d': 'v_%s', 'w.l': 'v_%s[15:0]', 'w.h': 'v_%s[31:16]', 'b.l': 'v_%s[7:0]', 'b.h': 'v_%s[15:8]'}[f] % b[1], w
            if b[0] == 'member' and b[1][0] == 'id' and self.locals.get(b[1][1]) == 'PAIR':
                f = b[2] + '.' + e[2]
                w = {'w.l': 16, 'w.h': 16, 'b.l': 8, 'b.h': 8}[f]
                return {'w.l': 'v_%s[15:0]', 'w.h': 'v_%s[31:16]', 'b.l': 'v_%s[7:0]', 'b.h': 'v_%s[15:8]'}[f] % b[1][1], w
        raise Unsupported('lvalue ' + k)

    def store(self, lv, width, rhs32):
        """blocking write of a 32-bit value, truncated to `width`"""
        if width == 32:
            self.emit('%s = %s;' % (lv, rhs32))
        else:
            self.emit('x32 = %s;' % rhs32)
            self.emit('%s = x32[%d:0];' % (lv, width - 1))

    # -------- lift RM(...) calls out of an expression tree: emit a read step for each, in evaluation order
    def lift(self, e):
        if not isinstance(e, tuple):
            return e
        if e[0] == 'call' and e[1] == 'RM':
            addr = self.val(self.lift(e[2][0]))
            self.emit("xa32 = %s;" % addr)
            self.emit("bus_a <= xa32[15:0]; bus_op <= BUS_RD; hstep <= hstep + 8'd1;")
            self.new_step()
            self.emit("rd_data32 = {24'b0, rd_data};")
            return e
        if e[0] == 'call':
            return (e[0], e[1], [self.lift(a) for a in e[2]])
        return tuple(self.lift(x) if isinstance(x, tuple) else ([self.lift(y) for y in x] if isinstance(x, list) else x) for x in e)

    def has_bus(self, e):
        if isinstance(e, tuple):
            if e[0] == 'call' and e[1] in ('RM', 'WM', 'RDOPARG', 'RDOP'): return True
            return any(self.has_bus(x) for x in e)
        if isinstance(e, list):
            return any(self.has_bus(x) for x in e)
        return False

    # -------- statements
    @staticmethod
    def ends_in_return(st):
        return st == ('return',) or (st[0] == 'block' and st[1] and st[1][-1] == ('return',))

    def stmts(self, lst):
        for i, s in enumerate(lst):
            if s[0] == 'if' and s[3] is None and self.ends_in_return(s[2]):
                if self.has_bus(s[2]):
                    raise Unsupported('bus access in the early-return branch')
                rest = lst[i + 1:]
                if self.has_bus(rest):
                    # overlay opcodes (MVI A / MVI L / LXI H): the test is the first thing in the handler; the rest, with its bus steps, is the else branch
                    if len(self.steps) != 1 or self.pending_close:
                        raise Unsupported('bus access after early return')
                    self.emit("if (%s != 32'd0) begin" % self.val(self.lift(s[1])))
                    self.stmt(s[2])
                    self.emit("ex_done <= 1'b1;")
                    self.emit('end else begin')
                    self.pending_close = True
                    self.stmts(rest)
                    return
                self.emit("if (%s != 32'd0) begin" % self.val(self.lift(s[1])))
                self.emit('end else begin')
                self.stmts(rest)
                self.emit('end')
                return
            self.stmt(s)

    def stmt(self, s):
        k = s[0]
        if k == 'block':
            self.stmts(s[1])
        elif k == 'decl':
            ty = s[1]
            for name, init in s[2]:
                self.locals[name] = ty
                if init is not None:
                    self.assign_to(('id', name), init)
        elif k == 'expr':
            self.expr_stmt(s[1])
        elif k == 'if':
            if self.has_bus(s[2]) or (s[3] is not None and self.has_bus(s[3])):
                raise Unsupported('bus access inside if')
            cond = self.val(self.lift(s[1]))
            self.emit('if (%s != 32\'d0) begin' % cond)
            self.stmt(s[2])
            if s[3] is not None:
                self.emit('end else begin')
                self.stmt(s[3])
            self.emit('end')
        elif k == 'switch':
            if self.has_bus(s[2]):
                raise Unsupported('bus access inside switch')
            self.emit('case (%s)' % self.val(s[1]))
            for label, body in s[2]:
                self.emit(('default' if label == 'default' else self.val(label).replace("32'd", "32'd")) + ': begin')
                for st in body:
                    if st[0] != 'break':
                        self.stmt(st)
                self.emit('end')
            self.emit('endcase')
        elif k in ('break', 'return'):
            pass
        else:
            raise Unsupported('stmt ' + k)

    def assign_to(self, lhs, rhs):
        rhs = self.lift(rhs)
        lv, w = self.lval(lhs)
        self.store(lv, w, self.val(rhs))

    def expr_stmt(self, e):
        k = e[0]
        if k == 'assign':
            op, l, r = e[1], e[2], e[3]
            while r[0] == 'assign' and r[1] == '=':
                self.expr_stmt(r)
                r = r[2]
            r = self.lift(r)
            lv, w = self.lval(l)
            if op == '=':
                self.store(lv, w, self.val(r))
            else:
                bop = op[:-1]
                cur = self.val(l)
                self.store(lv, w, '(%s %s %s)' % (cur, bop, self.val(r)))
        elif k in ('postinc', 'preinc'):
            lv, w = self.lval(e[2])
            self.store(lv, w, '(%s %s 32\'d1)' % (self.val(e[2]), '+' if e[1] == '++' else '-'))
        elif k == 'comma':
            self.expr_stmt(e[1]); self.expr_stmt(e[2])
        elif k == 'call':
            self.call_stmt(e[1], e[2])
        else:
            raise Unsupported('expression statement ' + k)

    def call_stmt(self, n, a):
        if n == 'RDOPARG' or n == 'RDOP':
            lv, w = self.lval(a[0])
            self.emit('bus_a <= r_pc; bus_op <= BUS_RD; hstep <= hstep + 8\'d1; r_pc = r_pc + 16\'d1;')
            self.new_step()
            self.store(lv, w, "{24'b0, rd_data}")
        elif n == 'WM':
            a = self.lift_all(a)
            self.emit("xa32 = %s;" % self.val(a[0]))
            self.emit("xd32 = %s;" % self.val(a[1]))
            self.emit("bus_a <= xa32[15:0]; bus_wd <= xd32[7:0]; bus_op <= BUS_WR; hstep <= hstep + 8'd1;")
            self.new_step()
        elif n == 'WP':
            a = self.lift_all(a)
            self.emit("xa32 = %s;" % self.val(a[0]))
            self.emit("xd32 = %s;" % self.val(a[1]))
            self.emit('wp(xa32[2:0], xd32[7:0]);')
        elif n in SIDE_CALLS:
            a = self.lift_all(a)
            if a:
                self.emit("xd32 = %s;" % self.val(a[0]))
                self.emit('%s(xd32[7:0]);' % SIDE_CALLS[n])
            else:                                   # upd7810_write_EOM() / _TXB(): act on the register just written
                self.emit('%s(%s);' % (SIDE_CALLS[n], {'do_write_eom': 'r_eom', 'do_write_txb': 'r_txb'}[SIDE_CALLS[n]]))
        elif n in ('ZHC_ADD', 'ZHC_SUB'):
            a = self.lift_all(a)
            self.emit('%s(%s, %s, %s);' % ('zhc_add' if n == 'ZHC_ADD' else 'zhc_sub', *[self.val(x) for x in a]))
        elif n in ('SKIP_CY', 'SKIP_NC', 'SKIP_Z', 'SKIP_NZ'):
            self.emit({'SKIP_CY': 'if (r_psw[0]) r_psw[5] = 1\'b1;', 'SKIP_NC': 'if (!r_psw[0]) r_psw[5] = 1\'b1;',
                       'SKIP_Z': 'if (r_psw[6]) r_psw[5] = 1\'b1;', 'SKIP_NZ': 'if (!r_psw[6]) r_psw[5] = 1\'b1;'}[n])
        elif n == 'SET_Z':
            a = self.lift_all(a)
            self.emit('if (%s != 32\'d0) r_psw[6] = 1\'b0; else r_psw[6] = 1\'b1;' % self.val(a[0]))
        elif n == 'm_ram_view.select':
            self.emit("r_ramview = 1'b1;")
        elif n == 'm_ram_view.disable':
            self.emit("r_ramview = 1'b0;")
        elif n == 'logerror':
            self.emit('illegal_seen = 1\'b1;')
        else:
            raise Unsupported('call ' + n)

    def lift_all(self, args):
        return [self.lift(x) for x in args]


MACRO_STMT = ('ZHC_ADD', 'ZHC_SUB', 'SKIP_CY', 'SKIP_NC', 'SKIP_Z', 'SKIP_NZ', 'SET_Z')


def preprocess(body):
    # bare macros without parentheses (SKIP_CY;) are parsed as identifiers: turn them into calls
    return re.sub(r'\b(SKIP_CY|SKIP_NC|SKIP_Z|SKIP_NZ)\b(?!\s*\()', r'\1()', body)


def translate(name, body):
    g = Gen(name)
    toks = tokenize(preprocess(body))
    p = Parser(toks)
    lst = p.block()
    if p.peek()[0] != 'eof':
        raise SyntaxError('trailing tokens')
    g.stmts(lst)
    if g.pending_close:
        g.emit('end')
        g.pending_close = False
    g.emit('ex_done <= 1\'b1;')
    return g


class DivGen:
    """DIV A / DIV B / DIV C (EA / r -> EA, remainder -> r; r = 0: r = EAL, EA = 0xffff) as a restoring division of one bit per engine step instead of the
    combinational 16 / 8 divider of the C++ (43 ns of logic would not meet the engine's 4-clock budget)."""
    locals = {'dr': 'uint32_t', 'dn': 'uint32_t'}

    def __init__(self, reg):
        self.steps = [
            ["if (%s == 8'd0) begin" % reg,
             "  %s = r_ea[7:0];" % reg,
             "  r_ea = 16'hffff;",
             "  ex_done <= 1'b1;",
             "end else begin",
             "  v_dr = 32'd0; v_dn = 32'd16; hstep <= hstep + 8'd1;",
             "end"],
            ["if (v_dn != 32'd0) begin",
             "  x32 = {v_dr[30:0], r_ea[15]};",
             "  r_ea = {r_ea[14:0], 1'b0};",
             "  if (x32 >= {24'd0, %s}) begin x32 = x32 - {24'd0, %s}; r_ea[0] = 1'b1; end" % (reg, reg),
             "  v_dr = x32; v_dn = v_dn - 32'd1;",
             "end else begin",
             "  %s = v_dr[7:0];" % reg,
             "  ex_done <= 1'b1;",
             "end"]]


SPECIAL = {'DIV_A': 'r_va[7:0]', 'DIV_B': 'r_bc[15:8]', 'DIV_C': 'r_bc[7:0]'}


def main():
    ops = open(os.path.join(SRC, 'upd7810_opcodes.cpp'), encoding='utf-8').read().replace('\r\n', '\n')
    funcs = dict((n, b) for n, b in re.findall(r'^void upd7810_device::(\w+)\(\)\n\{\n(.*?)^\}\n', ops, re.M | re.S))
    tbl = open(os.path.join(SRC, 'upd7810_table.cpp'), encoding='utf-8').read().replace('\r\n', '\n')
    tbl = re.sub(r'/\*.*?\*/', '', tbl, flags=re.S)
    tbl = re.sub(r'//[^\n]*', '', tbl)
    entries = {}
    for tname in TABLES:
        m = re.search(r'upd7810_device::%s\[256\] =\n\{\n(.*?)\n\};' % tname, tbl, re.S)
        rows = re.findall(r'\{&upd7810_device::(\w+),\s*(\d+),\s*(\d+),\s*(\d+),\s*([A-Za-z0-9|]+)\s*\}', m.group(1))
        assert len(rows) == 256, (tname, len(rows))
        entries[tname] = rows
    used = sorted(set(r[0] for t in entries.values() for r in t))
    report = []
    gens = {}
    for h in used:
        if h in ('illegal', 'illegal2') or h not in funcs:
            continue
        try:
            gens[h] = translate(h, funcs[h])
        except (Unsupported, SyntaxError, KeyError, IndexError) as ex:
            report.append('%-22s %s' % (h, ex))
    for h, reg in SPECIAL.items():
        gens[h] = DivGen(reg)
    hids = {h: i + 1 for i, h in enumerate(sorted(gens))}      # 0 = illegal / unsupported
    # ---- ops file
    o = ['// Generated by sim/upd78c10/gen_rtl.py from MAME 0.289 upd7810_opcodes.cpp (BSD-3-Clause, Juergen Buchmueller). Do not edit.',
         'case (hid)']
    for h in sorted(gens):
        g = gens[h]
        o.append("  10'd%d: begin // %s" % (hids[h], h))
        o.append('    case (hstep)')
        for i, st in enumerate(g.steps):
            o.append("      8'd%d: begin" % i)
            for line in st:
                o.append('        ' + line)
            o.append('      end')
        o.append("      default: ex_done <= 1'b1;")
        o.append('    endcase')
        o.append('  end')
    o.append("  default: begin illegal_seen = 1'b1; ex_done <= 1'b1; end")
    o.append('endcase')
    open(os.path.join(RTL, 'upd78c10_ops.svh'), 'w', newline='\n').write('\n'.join(o) + '\n')
    # ---- locals declaration (max over handlers: all 32 bit)
    names = sorted(set(n for g in gens.values() for n in g.locals))
    open(os.path.join(RTL, 'upd78c10_vars.svh'), 'w', newline='\n').write(
        '// Generated by sim/upd78c10/gen_rtl.py: handler locals\n' + ''.join('logic [31:0] v_%s;\n' % n for n in names))
    # ---- table file: function tab(input [10:0] idx) -> {hid[9:0], oplen[1:0], cycles[5:0], cycles_skip[5:0], mask[1:0]}
    tids = {t: i for i, t in enumerate(TABLES)}
    t = ['// Generated by sim/upd78c10/gen_rtl.py from MAME 0.289 upd7810_table.cpp (s_opXX_7810, s_op48..s_op74). Do not edit.',
         '// idx = {table[2:0], opcode[7:0]};  result = {hid[9:0], oplen[2:0], cycles[5:0], cycles_skip[5:0], mask_l0l1[1:0]}   (mask bit1 = L1, bit0 = L0)',
         'function automatic [26:0] tab(input [10:0] idx);', '  case (idx)']
    for tname in TABLES:
        for op, (h, ln, cy, cs, mk) in enumerate(entries[tname]):
            mask = (2 if 'L1' in mk else 0) | (1 if 'L0' in mk else 0)
            hid = hids.get(h, 0)
            t.append("    11'd%d: tab = {10'd%d, 3'd%s, 6'd%s, 6'd%s, 2'd%d};" % (tids[tname] * 256 + op, hid, ln, cy, cs, mask))
    t += ["    default: tab = 27'd0;", '  endcase', 'endfunction']
    open(os.path.join(RTL, 'upd78c10_tab.svh'), 'w', newline='\n').write('\n'.join(t) + '\n')
    # which handlers does the table use that are unsupported?
    unsup_used = {}
    for tname in TABLES:
        for op, (h, ln, cy, cs, mk) in enumerate(entries[tname]):
            if h not in gens and h not in ('illegal', 'illegal2'):
                unsup_used.setdefault(h, []).append('%s:%02X' % (tname, op))
    rep = ['translated: %d handlers, not translated: %d' % (len(gens), len(report))] + report
    rep += ['', 'not translated and used by the 78C10 tables (opcode -> illegal):'] + ['  %s  %s' % (h, ' '.join(v)) for h, v in sorted(unsup_used.items())]
    open(os.path.join(HERE, 'gen_report.txt'), 'w').write('\n'.join(rep) + '\n')
    print('\n'.join(rep[:60]))


if __name__ == '__main__':
    main()
