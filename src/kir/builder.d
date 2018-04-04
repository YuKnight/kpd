module kir.builder;

import std.stdio;
import std.range.primitives;
import std.conv;
import std.traits;

import kir.instr;
import kir.ir_mod;

import sema.visitor;
import sema.symbol;
import sema.infer;
import sema.type;

import diag.engine;
import compiler_error;
import kt;
import logger;
import ast;
import logger;
import krug_module;

T pop(T)(ref T[] array) {
	T val = array.back;
	array.popBack();
	return val;
}

uint temp = 0;
string gen_temp() {
	return "t" ~ to!string(temp++);
}

// this is a stupid crazy hack and im not sure how i feel about this
// but basically we have the NORMAL build_block and then
// we have a version which builds blocks but handles all of the
// yield stuff.
// whenever we handle a Block_Expression_Node, we set
// the current build_block to handle it for YIELDS, and once
// we're done we set it _back_ to the default block builder!
// stupid hacky thing but it works!
alias Block_Builder_Function = Label delegate(kir.instr.Function current_func,
		ast.Block_Node block, Basic_Block b = null);
		
class Kir_Builder : Top_Level_Node_Visitor {

	Kir_Module ir_mod;
	kir.instr.Function curr_func;

	// fuck me what am I doing  
	Block_Builder_Function build_block;

	this(string mod_name, string sub_mod_name) {
		ir_mod = new Kir_Module(mod_name, sub_mod_name);
		build_block = &build_normal_bb;
	}

	override void analyze_named_type_node(ast.Named_Type_Node) {
	}

	// NOTE:
	// taking a basic block to build onto is a hack so that
	// we can set 'last_looping_bb' for the
	// analyze_loop_node and analyze_while_node
	// i.e. we can push the block ourselves, set the 'last_looping_bb'
	// and then pass it. OTHERWISE if we try set it we have to do
	// it AFTER this function is executed... which means that we
	// will have already emitted the code for the statements that
	// need it (i.e. a next_statement_node) and thus 'last_looping_bb'
	// will be null.
	Label build_normal_bb(kir.instr.Function current_func, ast.Block_Node block, Basic_Block b = null) {
		auto bb = b is null ? push_bb() : b;

		foreach (stat; block.statements) {
			visit_stat(stat);
		}

		return new Label(bb.name(), bb);
	}	 

	kt.Kir_Type conv_type_op(Type_Operator to) {
		final switch (to.name) {
		case "s8": return get_int(8);
		case "s16": return get_int(16);
		case "s32": return get_int(32);
		case "s64": return get_int(64);

		case "u8": return get_uint(8);
		case "u16": return get_uint(16);
		case "u32": return get_uint(32);
		case "u64": return get_uint(64);

		case "f32": return get_float(32);
		case "f64": return get_float(64);

		case "bool": return get_uint(8);
		case "rune": return get_int(32);

		case "void": return VOID_TYPE;

		case "string": return STRING_TYPE;
		}

		assert(0);
	}

	// convert a type from the type system
	// used in the type infer/check pass
	// into a krug IR or KIR type.
	kt.Kir_Type conv(Type t) {
		if (auto to = cast(Type_Operator) t) {
			return conv_type_op(to);
		}
		else if (auto ptr = cast(Pointer) t) {
			return new Pointer_Type(conv(ptr.base));
		}

		logger.Fatal("kir_builder: unhandled type conversion from\t", to!string(t));
		assert(0);
	}

	kt.Kir_Type conv_prim_type(ast.Primitive_Type_Node prim) {
		switch (prim.type_name.lexeme) {
			// signed integers
		case "s8":
			return get_int(8);
		case "s16":
			return get_int(16);
		case "s32":
			return get_int(32);
		case "s64":
			return get_int(64);

			// unsigned integers
		case "u8":
			return get_uint(8);
		case "u16":
			return get_uint(16);
		case "u32":
			return get_uint(32);
		case "u64":
			return get_uint(64);

		case "bool":
			return get_uint(8);
		case "rune":
			return get_int(32);

		case "f32":
			return get_float(32);
		case "f64":
			return get_float(64);

		case "void": return VOID_TYPE;

		case "string": return STRING_TYPE;

		default:
			break;
		}

		// TODO f32 and f64.

		logger.Error("Unhandled conversion of primitive type to kir type ", to!string(
				prim));
		return null;
	}

	kt.Kir_Type get_sym_type(ast.Symbol_Node sym) {
		if (sym.resolved_symbol is null) {
			logger.Fatal("Unresolved symbol node leaking! ", to!string(sym));
			return VOID_TYPE;
		}

		if (auto sym_val = cast(Symbol_Value) sym.resolved_symbol) {
			return get_type(sym_val.reference);
		}

		assert(0, "shit!");
	}

	kt.Kir_Type get_array_type(Array_Type_Node arr) {
		import kir.eval;
		auto res = try_evaluate_expr(arr.value);
		if (res.failed) {
			// TODO store the tokens for array types...
			Diagnostic_Engine.throw_error(COMPILE_TIME_EVAL, arr.value.get_tok_info(), arr.value.get_tok_info());
			res.value = 0;
		}
		return new kt.Array_Type(get_type(arr.base_type), res.value);
	}

	// convert an AST type to a krug ir type
	kt.Kir_Type get_type(Node t) {
		assert(t !is null, "get_type null type!");

		if (auto prim = cast(Primitive_Type_Node) t) {
			return conv_prim_type(prim);
		}
		else if (auto arr = cast(Array_Type_Node) t) {
			return get_array_type(arr);
		}
		else if (auto ptr = cast(Pointer_Type_Node) t) {
			return new kt.Pointer_Type(get_type(ptr.base_type));
		}

		else if (auto path = cast(Path_Expression_Node) t) {
			// FIXME
			return get_type(path.values[$-1]);
		}
		else if (auto sym = cast(Symbol_Node) t) {
			return get_sym_type(sym);
		}
		else if (auto var = cast(Variable_Statement_Node) t) {
			assert(var.type !is null, "leaking unresolved type for Variable_Statement_Node");
			return get_type(var.type);
		}
		else if (auto fn = cast(Function_Node) t) {
			// void...
			if (fn.return_type is null) {
				return VOID_TYPE;
			}
			return get_type(fn.return_type);
		}
		else if (auto bin = cast(Binary_Expression_Node) t) {
			// FIXME
			// the assumption here is based off
			// the binary expression should have 
			// the left and right hand expressions types
			// unified from type inference
			return get_type(bin.left);
		}
		else if (auto param = cast(Function_Parameter) t) {
			return get_type(param.type);
		}

		logger.Error("Leaking unresolved type:\n\t", to!string(t), "\n\t", to!string(typeid(t)));

		// FIXME just pretend it's an integer for now!
		return get_int(32);
	}

	// we generate one control flow graph per function
	// convert the ast.Block_Node into a bunch of basic blocks
	// 
	// the flow can only enter via the FIRST instruction of the
	// basic block
	// control will leave the block without halting or branching
	// basic block is a node in a control flow graph.
	//
	// 1. the first instruction is a leader.
	// 2. any instruction that is the target of a jump is a leader.
	// 3. any instruction that follows a jump is a leader.
	override void analyze_function_node(ast.Function_Node func) {
		Kir_Type return_type = VOID_TYPE;
		if (func.return_type !is null) {
			return_type = get_type(func.return_type);
		}

		// FIXME this is kind of awkward
		// NOTE I tried to make a Kir_Module for c_functions
		// nested in every module, but this causes a seg fault
		// with the D gc smallAlloc? lol
		if (func.has_attribute("c_func")) {
			curr_func = new kir.instr.Function(func.name.lexeme, return_type, ir_mod);
			ir_mod.c_funcs[curr_func.name] = curr_func;
		}
		else {
			curr_func = ir_mod.add_function(func.name.lexeme, return_type);
		}

		writeln("ATTRIBS FOR FUNC ", func.name);
		foreach (name; func.get_attribs().byKey) {
			writeln(" - ", name);
		}

		curr_func.set_attributes(func.get_attribs());

		// this is kinda hacky.
		bool is_proto = func.func_body is null;

		// only generate the bb0 params block
		// if we have params on this function
		if (!is_proto) push_bb();

		// alloc all the params
		foreach (p; func.params) {
			auto param_alloc = new Alloc(get_type(p.type), p.twine.lexeme);
			if (!is_proto) curr_func.add_alloc(param_alloc);
			curr_func.params ~= param_alloc;
		}

		if (is_proto) return;

		build_block(curr_func, func.func_body);

		// if there are no instructions in the last basic
		// block add a return
		// OR if the last instruction is not a return!
		if (curr_func.curr_block.instructions.length == 0 || !cast(Return) curr_func
				.last_instr()) {
			curr_func.add_instr(new Return(new Void_Type()));
		}
	}

	// i feel like this is all completely shit and
	// probably wont work. do this properly! but for now
	// it works for most of the test cases?
	Value build_binary_expr(ast.Binary_Expression_Node binary) {
		Value left = build_expr(binary.left);
		Value right = build_expr(binary.right);
		auto expr = new BinaryOp(left.get_type(), binary.operand, left, right);

		// create a store if we're dealing with an assignment
		if (binary.operand.lexeme == "=") {
			return new Store(left.get_type(), left, right);
		}

		auto temp = new Alloc(left.get_type(), gen_temp());
		curr_func.add_instr(temp);

		auto store = new Store(left.get_type(), temp, expr);
		curr_func.add_instr(store);
		return new Identifier(temp.get_type(), temp.name);
	}

	Value build_path(ast.Path_Expression_Node path) {
		if (path.values.length == 1) {
			return build_expr(path.values[0]);
		}

		foreach (v; path.values) {
			writeln(v);
		}

		assert(0);
	}

	Value build_index_expr(ast.Index_Expression_Node node) {
		Value addr = build_expr(node.array);
		Value sub = build_expr(node.index);
		return new Index(addr.get_type(), addr, sub);
	}

	Value value_at(ast.Expression_Node e) {
		return new Deref(build_expr(e));
	}

	Value addr_of(ast.Expression_Node e) {
		return new AddrOf(build_expr(e));
	}

	Value build_unary_expr(ast.Unary_Expression_Node unary) {
		// grammar.d
		// "+", "-", "!", "^", "@", "&"
		final switch (unary.operand.lexeme) {
		case "+":
		case "-":
		case "!":
		case "^":
			return new UnaryOp(unary.operand, build_expr(unary.value));
		case "@":
			return value_at(unary.value);
		case "&":
			return addr_of(unary.value);
		}
		assert(0, "unhandled build unary expr in builder.");
	}

	Value build_call(ast.Call_Node call) {
		Value left = build_expr(call.left);
		Value[] args;
		foreach (arg; call.args) {
			args ~= build_expr(arg);
		}
		return new Call(left.get_type(), left, args);
	}

	Basic_Block push_bb(string namespace = "") {
		// assuming the prior hack!
		if (ref this.build_block ==  & build_normal_bb) {
			return curr_func.push_block(namespace);
		}

		if (namespace != "") {
			namespace = "_" ~ namespace;
		}
		return curr_func.push_block("_yield" ~ namespace);
	}

	// this is a specialize block thingy majig
	Value build_eval_expr(ast.Block_Expression_Node eval) {
		// hm! how should this be done
		// we need to store it in a temporary
		// but we need to know what type it is
		// because the type sema phases are gone
		// the block_Expr_node has no type
		//
		// when i do finally implement this...
		// create an alloc with the same type as the 
		// eval block.
		// when we build the yield expression, we
		// do a store into the alloc we created
		// then we return the value at the alloc
		// 
		// for now! NOTE NOTE NOTE
		// we are going to assume the type is
		// a signed 32 bit integer cos lol

		auto bb = push_bb("_yield");

		// TODO type here is not a s32!!
		Alloc a = new Alloc(get_int(32), bb.name() ~ "_" ~ gen_temp());
		curr_func.add_instr(a);

		// what the fuck am i doing!
		this.build_block = delegate(kir.instr.Function curr_func, ast.Block_Node block,
				Basic_Block unused = null) {
			auto bb = push_bb();

			foreach (s; block.statements) {
				if (auto yield = cast(ast.Yield_Statement_Node) s) {
					auto val = build_expr(yield.value);
					curr_func.add_instr(new Store(a.get_type(), a, val));
				}
				else if (auto b = cast(ast.Block_Node) s) {
					build_block(curr_func, b);
				}
				else {
					visit_stat(s);
				}
			}

			return new Label(bb.name(), bb);
		};
		build_block(curr_func, eval.block);

		// this is a crazy hack! im not sure how i feel
		// about this.
		// RESET the build block shit
		this.build_block = &build_normal_bb;

		push_bb();

		// hm
		return new Identifier(a.get_type(), a.name);
	}

	string add_constant(Value v) {
		auto const_temp_name = gen_temp();
		ir_mod.constants[const_temp_name] = v;
		return const_temp_name;
	}

	// FIXME this is a bit funky!
	Value build_string_const(String_Constant_Node str) {
		// generate a constant 
		// as well as a reference to the
		// constant
		string const_ref = add_constant(new Constant(new Pointer_Type(get_uint(8)), str.value));
		auto string_data_ptr = new Constant_Reference(new Pointer_Type(get_uint(8)), const_ref);

		// c-style string is simply a raw unsigned
		// 8 bit integer pointer
		if (str.type == String_Type.C_STYLE) {
			return string_data_ptr;
		}

		// TODO we assume its pascal here..
		// pascal type is the pointer as well as the length of
		// the array as a struct.
		auto val = new Composite(STRING_TYPE);
		val.add_value(new Constant(get_uint(64), to!string(str.value.length)));
		val.add_value(string_data_ptr);
		return val;
	}

	Value build_expr(ast.Expression_Node expr) {
		if (auto integer_const = cast(Integer_Constant_Node) expr) {
			// FIXME
			return new Constant(get_int(32), to!string(integer_const.value));
		}
		else if (auto float_const = cast(Float_Constant_Node) expr) {
			// FIXME
			return new Constant(get_float(64), to!string(float_const.value));
		}
		else if (auto rune_const = cast(Rune_Constant_Node) expr) {
			// runes are a 4 byte signed integer.
			return new Constant(get_int(32), to!string(rune_const.value));
		}
		else if (auto index = cast(Index_Expression_Node) expr) {
			return build_index_expr(index);
		}
		else if (auto binary = cast(Binary_Expression_Node) expr) {
			return build_binary_expr(binary);
		}
		else if (auto paren = cast(Paren_Expression_Node) expr) {
			return build_expr(paren.value);
		}
		else if (auto path = cast(Path_Expression_Node) expr) {
			return build_path(path);
		}
		else if (auto sym = cast(Symbol_Node) expr) {
			return new Identifier(get_type(sym), sym.value.lexeme);
		}
		else if (auto cast_expr = cast(Cast_Expression_Node) expr) {
			// TODO float to int vice versa
			// or truncate to smaller type i.e. u32 to u8
			// for now just spit out the build expr
			return build_expr(cast_expr.left);
		}
		else if (auto call = cast(Call_Node) expr) {
			return build_call(call);
		}
		else if (auto unary = cast(Unary_Expression_Node) expr) {
			return build_unary_expr(unary);
		}
		else if (auto eval = cast(Block_Expression_Node) expr) {
			return build_eval_expr(eval);
		}
		else if (auto str_const = cast(String_Constant_Node) expr) {
			return build_string_const(str_const);
		}
		else if (auto bool_const = cast(Boolean_Constant_Node) expr) {
			string value = bool_const.value ? "1" : "0";
			return new Constant(get_uint(8), value);
		}

		logger.Fatal("kir_builder: unhandled build_expr ", to!string(expr), " -> ", to!string(typeid(expr)));
		assert(0);
	}

	void analyze_return_node(ast.Return_Statement_Node ret) {
		auto ret_instr = new Return(new Void_Type());

		// its not a void type
		if (ret.value !is null) {
			ret_instr.set_type(get_type(ret.value));
			ret_instr.results ~= build_expr(ret.value);
		}

		// TODO return values
		curr_func.add_instr(ret_instr);
	}

	void analyze_if_node(ast.If_Statement_Node if_stat) {
		Value condition = build_expr(if_stat.condition);

		If jmp = new If(condition);
		curr_func.add_instr(jmp);
		jmp.a = build_block(curr_func, if_stat.block);

		// new block for else stuff
		jmp.b = new Label(push_bb());
	}

	void analyze_loop_node(ast.Loop_Statement_Node loop) {
		auto entry = new Label(push_bb());
		build_block(curr_func, loop.block, entry.reference);
		curr_func.add_instr(new Jump(entry));

		// jump must be the last instruction in it's block!
		// so we need to push a basic block here.
		auto exit = new Label(push_bb());

		// re-write all of the jumps that
		// are for break statements to jump to
		// the exit basic block
		foreach (k, v; break_rewrites) {
			k.instructions[v] = new Jump(exit);
			break_rewrites.remove(k);
		}

		// re-write all of the jumps that
		// are for next statements to jump
		// to the entry basic block
		foreach (k, v; next_rewrites) {
			k.instructions[v] = new Jump(entry);
			next_rewrites.remove(k);
		}
	}

	// these maps keep track of the jump addresses
	// for break and next statement instructions
	// as well as what basic blocks they belong in
	// once we have done generating the IR for 
	// the while/loop construct, we then re-write
	// all of these stored addresses to the correct
	// labels
	ulong[Basic_Block] break_rewrites;
	ulong[Basic_Block] next_rewrites;

	void analyze_next_node(ast.Next_Statement_Node n) {
		auto jmp_addr = curr_func.curr_block.instructions.length;
		curr_func.add_instr(new Jump(null));
		next_rewrites[curr_func.curr_block] = jmp_addr;
	}

	void analyze_break_node(ast.Break_Statement_Node b) {
		auto jmp_addr = curr_func.curr_block.instructions.length;
		curr_func.add_instr(new Jump(null));
		break_rewrites[curr_func.curr_block] = jmp_addr;
	}

	void analyze_global(ast.Variable_Statement_Node var) {
		// TODO what if there is no value assigned?
		// TODO make sure it's allocated... we can't really
		// introduce temporaries as a global...

		if (var.value is null) {
			assert("global no value unhandled");
		}

		Value v = build_expr(var.value);
		ir_mod.constants[var.twine.lexeme] = v;
	}

	override void analyze_let_node(ast.Variable_Statement_Node var) {
		auto typ = get_type(var.type);
		assert(typ !is null);

		if (curr_func is null) {
			// it's a global
			analyze_global(var);
			return;
		}

		// TODO handle global variables.
		auto addr = curr_func.add_alloc(new Alloc(typ, var.twine.lexeme));

		if (var.value !is null) {
			auto val = build_expr(var.value);
			curr_func.add_instr(new Store(val.get_type(), addr, val));
		}
	}

	void analyze_while_node(ast.While_Statement_Node loop) {
		auto loop_check = new Label(push_bb());
		Value v = build_expr(loop.condition);
		If jmp = new If(v);
		curr_func.add_instr(jmp);

		auto loop_body = new Label(push_bb());
		build_block(curr_func, loop.block, loop_body.reference);
		curr_func.add_instr(new Jump(loop_check));

		jmp.a = loop_body;
		jmp.b = new Label(push_bb());

		// re-write all of the jumps that
		// are for break statements to jump to
		// the exit basic block
		foreach (k, v; break_rewrites) {
			k.instructions[v] = new Jump(jmp.b);
			break_rewrites.remove(k);
		}

		// re-write all of the jumps that
		// are for next statements to jump
		// to the entry basic block
		foreach (k, v; next_rewrites) {
			k.instructions[v] = new Jump(loop_check);
			next_rewrites.remove(k);
		}
	}

	override void visit_stat(ast.Statement_Node node) {
		Basic_Block block_sample = curr_func.curr_block;

		if (auto let = cast(ast.Variable_Statement_Node) node) {
			analyze_let_node(let);
		}
		else if (auto ret = cast(ast.Return_Statement_Node) node) {
			analyze_return_node(ret);
		}
		else if (auto if_stat = cast(ast.If_Statement_Node) node) {
			analyze_if_node(if_stat);
		}
		else if (auto loop = cast(ast.Loop_Statement_Node) node) {
			analyze_loop_node(loop);
		}
		else if (auto loop = cast(ast.While_Statement_Node) node) {
			analyze_while_node(loop);
		}
		else if (auto b = cast(ast.Break_Statement_Node) node) {
			analyze_break_node(b);
		}
		else if (auto n = cast(ast.Next_Statement_Node) node) {
			analyze_next_node(n);
		}
		else if (auto e = cast(ast.Expression_Node) node) {
			auto v = build_expr(e);
			if (auto instr = cast(Instruction) v) {
				curr_func.add_instr(instr);
			}
		}
		else if (auto b = cast(ast.Block_Node) node) {
			build_block(curr_func, b);
		}
		else {
			logger.Warn("kir_builder: unhandled node: ", to!string(node));
		}

		if (block_sample.instructions.length == 0) {
			return;
		}

		auto last_instr = block_sample.instructions[$ - 1];
		last_instr.set_code(to!string(node));
	}

	Kir_Module build(ref Module mod, AST as_tree) {
		foreach (node; as_tree) {
			super.process_node(node);
		}
		return ir_mod;
	}
}
