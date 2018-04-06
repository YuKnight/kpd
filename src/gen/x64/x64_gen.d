module gen.x64.generator;

import std.stdio;
import std.conv;
import std.format;
import std.container.array;
import std.range.primitives;
import std.bitmanip : bitfields, FloatRep, DoubleRep;
import std.algorithm.searching : countUntil;
import std.process;
import std.random;

import logger;

import gen.x64.output;
import gen.x64.mangler;

import kt;
import kir.ir_mod;
import kir.instr;

class Block_Context {
	Function parent;

	long addr_ptr = 0;
	long[string] locals;
	uint alloc_instr_addr;

	this(Function parent) {
		this.parent = parent;
	}

	long size() {
		return addr_ptr;
	}

	long push_local(string name, int width) {
		long alloc_addr = addr_ptr;
		locals[name] = alloc_addr;
		addr_ptr += width;
		return alloc_addr;
	}

	// FIXME
	// return -1 if the name is not a local.
	long get_addr(string name) {
		if (name !in locals) {
			writeln("NO LOCAL '", name, "' in '", parent.name, "'!");
			foreach (k, v; locals) {
				writeln(k, " => ", v);
			}
			return -1;
		}
		return locals[name];
	}
}

string width_to_const_type(uint width) {
	final switch (width) {
	case 1:
		return "byte";
	case 2:
		return "short";
	case 4:
		return "long";
	case 8:
		return "quad";
	}
}

class X64_Generator {
	IR_Module mod;
	X64_Code code;
	Function curr_func;

	Block_Context[string] ctx;
	Block_Context curr_ctx;

	this() {
		code = new X64_Code;
	}

	// gets the address of the given
	// alloc in the current block context
	long get_alloc_addr(Alloc a) {
		return curr_ctx.get_addr(a.name);
	}
	long get_alloc_addr_by_name(string name) {
		return curr_ctx.get_addr(name);
	}

	string get_instr_suffix(uint width) {
		switch (width) {
		case 1: return "b";
		case 2: return "s";
		case 4: return "l";
		case 8: return "q";
		default: 
			writeln("warn no suffix!");
			return "";
		}
	}

	string get_const(Constant c) {
		auto type = c.get_type();
		if (auto integer = cast(Integer_Type) type) {
			return "$" ~ c.value;
		}
		else if (auto floating = cast(Floating_Type) type) {
			// todo mangle properly?
			string name = "_FC_" ~ thisProcessID.to!string(36) ~ "_" ~ uniform!uint.to!string(36);
			emit_data_const(name, c);
			return name ~ "(%rip)";
		}

		return "; unhandled constant, -- " ~ to!string(c);
	}

	// FIXME
	// we're hoping this is a constant...
	void emit_data_const(string name, Value v) {
		auto c = cast(Constant) v;
		if (!c) {
			logger.fatal("emit_data_const: unhandled value ", to!string(v));
		}

		string constant_type = width_to_const_type(c.get_type().get_width());

		// we can just set the value for most constants
		string constant_val = c.value;

		// floats we have to convert the floating value
		// into its float representation and spit it out
		// as an integer constant.
		if (auto f = cast(Floating_Type) c.get_type()) {
			final switch (f.get_width()) {
			case 4:
				FloatRep flt_rep;
				flt_rep.value = to!float(c.value);
				uint int_value = *(cast(uint*)(&flt_rep));
				constant_val = to!string(int_value);
				break;
			case 8:
				DoubleRep dbl_rep;
				dbl_rep.value = to!float(c.value);
				ulong int_value = *(cast(ulong*)(&dbl_rep));
				constant_val = to!string(int_value);
				break;
			}
		}

		// FIXME better type/string comparison
		else if (c.get_type().cmp(new Pointer_Type(get_uint(8)))) {
			constant_type = "asciz";
		}

		// data constants are written
		// in the data segment. this is restored
		// back to text.
		code.set_segment(Segment.Data);

		code.emit("{}:", name);
		code.emitt(".{} {}", constant_type, constant_val);

		// restore back to the text segment.
		code.set_segment(Segment.Text);
	}

	string add_binary_op(Binary_Op b) {
		string left = get_val(b.a);
		string right = get_val(b.b);
		return left;
	}

	string get_val(Value v) {
		if (auto c = cast(Constant) v) {
			return get_const(c);
		}
		else if (auto a = cast(Alloc) v) {
			long addr = get_alloc_addr(a);
			return to!string(addr) ~ "(%rsp)";
		}
		else if (auto r = cast(Identifier) v) {
			// first check if this is a param
			auto index = curr_ctx.parent.params.countUntil!("a.name == b")(r.name);
			if (index != -1) {
				auto param = curr_ctx.parent.params[index];
				if (index < registers.length) {
					// TODO get the type here.
					// for now just load the 64 bit reg
					string suff = get_instr_suffix(param.get_type().get_width());
					string which_reg = "r";
					if (suff == "l") which_reg = "e";
					// TOOD

					return "%" ~ which_reg ~ registers[index];
				}

				// VERY IMPORTANT NOTE:
				// we have to offset the index by 
				// the registers
				// because we only store arguments after
				// len(registers) in the locals
				// because normally
				// we look up args(i) where i > 6 
				// by registers[i]!
				auto arg_index = index - registers.length;
				auto addr = curr_ctx.get_addr("__arg_" ~ to!string(arg_index));
				return to!string(addr) ~ "(%rsp)";
			}

			long addr = get_alloc_addr_by_name(r.name);
			if (addr != -1) {
				return to!string(addr) ~ "(%rsp)";				
			}

			// look for the value in the globals.
			// if it is, it's a label so we can just spit
			// out the name?
			if (r.name in mod.constants) {
				// FIXME
				return "" ~ r.name ~ "(%rip)";
			}

			return "error!";
		}
		else if (auto c = cast(Constant_Reference) v) {
			return c.name ~ "(%rip)";
		}
		else if (auto i = cast(Call) v) {
			// eax or rax ?
			emit_call(i);
			return "%eax";
		}

		logger.fatal("unimplemented get_val " ~ to!string(v) ~ " ... " ~ to!string(typeid(v)));
		return "%eax, %eax # unimplemented get_val " ~ to!string(v);
	}

	void emit_cmp(Store s) {
		auto bin = cast(Binary_Op) s.val;

		// mov bin.left into eax
		code.emitt("movl {}, %eax", get_val(bin.a));
		
		// cmp bin.right with eax
		code.emitt("cmpl {}, %eax", get_val(bin.b));

		// one opt i've noticed here is it seems to be
		// cheaper instruction wise to emit a jump i.e.
		// jn jne jle, etc. rather than doing the comparison
		// and setting the AL register.
		// but because we cant really do this reasily right now
		// im doing it naively like so:

		switch (bin.op.lexeme) {
		case ">":
			code.emitt("setg %al");
			break;
		case "<":
			code.emitt("setb %al");
			break;

		case ">=":
			code.emitt("setge %al");
			break;
		case "<=":
			code.emitt("setle %al");
			break;

		case "==":
			code.emitt("sete %al");
			break;
		case "!=":
			code.emitt("setne %al");
			break;

		default:
			assert(0, "unhandled op!");
		}

		code.emitt("movzb %al, %eax");
		code.emitt("movl %eax, {}", get_val(s.address));
	}

	// a store where the value is
	// a binary operator
	// e.g.
	// t0 = a + b
	void emit_temp(Store s) {
		// todo properly select the register
		// here based on the width of the type
		// we are dealing with

		auto bin = cast(Binary_Op) s.val;
		code.emitt("movl {}, %eax", get_val(bin.a));

		string instruction;
		switch (bin.op.lexeme) {

		// hm!
		case ">":
		case "<":
		case ">=":
		case "<=":
		case "==":
		case "!=":
			return emit_cmp(s);

		case "+":
			instruction = "add";
			break;
		case "-":
			instruction = "sub";
			break;
		case "/":
			// TODO DIVISION!
			assert(0);
		case "*":
			instruction = "imul";
			break;
		default:
			logger.fatal("Unhandled instr selection for binary op ", to!string(bin));
			break;
		}

		auto width_bytes = s.get_type().get_width();
		instruction ~= get_instr_suffix(width_bytes);

		code.emitt("{} {}, %eax", instruction, get_val(bin.b));
		code.emitt("movl %eax, {}", get_val(s.address));
	}

	void emit_store(Store s) {
		// kind of hacky but ok
		if (auto bin = cast(Binary_Op) s.val) {
			emit_temp(s);
			return;
		}

		IR_Type t = s.get_type();

		string val = get_val(s.val);
		string addr = get_val(s.address);

		code.emitt("movl {}, %eax", val);
		code.emitt("movl %eax, {}", addr);
	}

	void emit_ret(Return ret) {
		if (ret.results !is null) {
			Value v = ret.results[0];
			code.emitt("movl {}, %eax", get_val(v));
		}

		// FIXME this wont work all the time...
		// i dont think?!

		// before we return from the function we 
		// have to de-allocate all the stack space
		// we allocated. note that we also set
		// the allocated space here because
		// when we emit the _initial_ subq allocation
		// instruction we don't know how much space
		// has been pushed to the stack!
		code.emitt_at(curr_ctx.alloc_instr_addr, "subq ${}, %rsp", to!string(curr_ctx.size()));
		code.emitt("addq ${}, %rsp", to!string(curr_ctx.size()));

		code.emitt("popq %rbp");
		code.emitt("ret");
	}

	void emit_if(If iff) {
		// emit the condition and 
		// check if it's true
		string condish = get_val(iff.condition);
		code.emitt("cmpb $1, {}", condish);

		code.emitt("je {}", mangle(iff.a));
		code.emitt("jmp {}", mangle(iff.b));
	}

	void emit_jmp(Jump j) {
		code.emitt("jmp {}", mangle(j.label));
	}

	static string[] registers = [
		"di", "si", "dx", "cx", "r8", "r9"
	];

	void emit_call(Call c) {
		// x86_64 calling convention...
		// following the System V AMD64 ABI conv
		// https://en.wikipedia.org/wiki/X86_calling_conventions

		/*
			The first six integer or pointer arguments are passed in registers RDI, RSI, RDX, RCX, R8, R9 
			(R10 is used as a static chain pointer in case of nested functions...), 

			while XMM0, XMM1, XMM2, XMM3, XMM4, XMM5, XMM6 and XMM7 are used for certain floating point arguments.

			..., additional arguments are passed on the stack. 
			Integral return values up to 64 bits in size are stored in RAX 
			while values up to 128 bit are stored in RAX and RDX. 

			Floating-point return values are similarly stored in XMM0 and XMM1.

			should be stack aligned on 16 byte boundary.
		*/

		import std.algorithm.comparison : min, max;

		string call_name = ";\n hlt"; // lol FIXME
		if (auto iden = cast(Identifier) c.left) {
			// since this is just a stand alone name
			// its probably going to be a function
			// registered in THIS module, so lets
			// look it up and see if it exists.
			auto func = mod.get_function(iden.name);
			assert(func !is null);
			call_name = mangle(func);
		}
		else {
			logger.fatal("unhandled invoke lefthand ! ", to!string(c.left), " for ", to!string(c));
		}

		if ((call_name in ctx) is null) {
			logger.verbose("Call context for '", call_name, "' does not exist!");
			foreach (k, v; ctx) {
				logger.verbose(k, " => ", to!string(v));
			}
			assert(0);
		}

		// the locals context for the function
		// we're calling.
		Block_Context call_frame_ctx = ctx[call_name];

		foreach (i, arg; c.args[0..min(c.args.length,registers.length)]) {
			auto w = arg.get_type().get_width();
			auto suffix = "q";

			string reg;
			if (i >= 4) {
				reg = registers[i] ~ (suffix == "l" ? "d" : "");
			} else {
				reg = (suffix == "q" ? "r" : "e") ~ registers[i];
			}

			// HACK FIXME
			string instr = "mov";
			if (auto ptr = cast(Pointer_Type) arg.get_type()) {
				instr = "lea";
			}

			// move the value into the register
			string val = get_val(arg);
			code.emitt("{}{} {}, %{}", instr, suffix, val, reg);
		}

		if (c.args.length >= registers.length) {
			foreach_reverse (i, arg; c.args[registers.length..$]) {
				// move the value via. the stack
				string val = get_val(arg);
				long addr = call_frame_ctx.get_addr("__arg_" ~ to!string(i));
				code.emitt("movq {}, {}(%rsp)", get_val(arg), to!string(addr));
			}
		}		

		code.emitt("xor %rax, %rax");
		code.emitt("call {}", call_name);
	}

	void emit_instr(Instruction i) {
		if (auto alloc = cast(Alloc)i) {
			auto addr = curr_ctx.push_local(alloc.name, alloc.get_type().get_width());
			logger.verbose("Emitting local ", to!string(alloc), " at addr ", to!string(addr), "(%rsp)");
		}
		else if (auto ret = cast(Return)i) {
			emit_ret(ret);
		}
		else if (auto store = cast(Store)i) {
			emit_store(store);
		}
		else if (auto iff = cast(If)i) {
			emit_if(iff);
		}
		else if (auto jmp = cast(Jump)i) {
			emit_jmp(jmp);
		}
		else if (auto c = cast(Call)i) {
			emit_call(c);
		}
		else {
			logger.fatal("x64_gen: unhandled instruction ", to!string(typeid(cast(Basic_Instruction)i)), ":\n\t", to!string(i));
		}
	}

	void emit_bb(Basic_Block bb) {
		code.emit("{}:", mangle(bb));
		foreach (instr; bb.instructions) {
			emit_instr(instr);
		}
	}

	void emit_mod(IR_Module mod) {
		this.mod = mod;

		code.set_segment(Segment.Data);
		foreach (k, v; mod.constants) {
			emit_data_const(k, v);
		}

		code.set_segment(Segment.Text);
		foreach (ref name, func; mod.c_funcs) {
			setup_func_proto(func);
		}
		foreach (ref name, func; mod.functions) {
			setup_func_proto(func);
		}

		foreach (ref name, func; mod.functions) {
			emit_func(func);
		}
	}

	void push_block_ctx(Function func) {
		auto new_ctx = new Block_Context(func);
		logger.verbose("Pushing local context for func '", func.name, "'");
		ctx[mangle(func)] = new_ctx;
		curr_ctx = new_ctx;
	}

	void setup_func_proto(Function func) {
		push_block_ctx(func);

		// push all of the param allocs
		// into the current block context
		// we mangle the names to __arg_N
		// where N is the index of the argument.
		if (func.params.length >= registers.length) {
			foreach_reverse (i, arg; func.params[registers.length..$]) {
				curr_ctx.push_local("__arg_" ~ to!string(i), arg.get_type().get_width());
			}
		}
	}

	void emit_func(Function func) {
		curr_func = func;
		// hm		
		if (func.has_attribute("c_func")) {
			return;
		}

		curr_ctx = ctx[mangle(func)];

		code.emit("{}:", mangle(func));

		code.emitt("pushq %rbp");
		code.emitt("movq %rsp, %rbp");

		// PLACEHOLDER value here, we subtract 0 from the
		// RSP but we later on MODIFY THIS to however much
		// bytes we allocated (aligned to a 16 byte boundary).
		// this is why we store the address which this instruction
		// was written to
		curr_ctx.alloc_instr_addr = code.emitt("subq $0, %rsp");

		foreach (ref bb; func.blocks) {
			emit_bb(bb);
		}

		// if there is no return instr
		// slap one on the end.
		if (!(cast(Return) func.last_instr())) {
			emit_ret(new Return(VOID_TYPE));
		}
	}
}

static int align_to(int n, int m) {
    int rem = n % m;
    return (rem == 0) ? n : n - rem + m;
}