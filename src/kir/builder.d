module kir.builder;

import std.stdio;
import std.range.primitives;
import std.conv;
import std.traits;
import std.algorithm.searching : countUntil;

import kir.instr;
import kir.ir_mod;
import kir.conv_type;

import sema.visitor;
import sema.symbol;
import sema.infer;
import sema.type;

import diag.engine;
import compiler_error;
import logger;
import tok : Token, Token_Type;
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

class Defer_Context {
	Symbol_Table curr_sym_table, previous;
	Statement_Node[] stat;
}
		
class IR_Builder : Top_Level_Node_Visitor {

	Module mod;
	IR_Module ir_mod;
	kir.instr.Function curr_func;

	Defer_Context[] defer_ctx;
	uint defer_ctx_ptr = -1;

	void push_defer_ctx() {
		if (defer_ctx_ptr >= defer_ctx.length) {
			defer_ctx.length *= 2;
		}
		logger.verbose("- push defer");
		defer_ctx[++defer_ctx_ptr] = new Defer_Context();
	}

	Defer_Context curr_defer_ctx() {
		assert(defer_ctx_ptr != -1);
		return defer_ctx[defer_ctx_ptr];
	}

	void pop_defer_ctx() {
		logger.verbose("- pop defer");
		defer_ctx_ptr--;
	}

	this(Module mod, string sub_mod_name) {
		this.ir_mod = mod.ir_mod;
		defer_ctx.length = 32;
	}

	override void analyze_named_type_node(ast.Named_Type_Node) {
	}

	override void visit_block(ast.Block_Node block, void delegate(Symbol_Table curr_stab) pre = null, void delegate(Symbol_Table curr_stab) post = null) {
		push_defer_ctx();
		super.visit_block(block, pre, delegate(Symbol_Table stab) {
			logger.verbose("- running defer");
			foreach_reverse (ref stat; curr_defer_ctx().stat) {
				visit_stat(stat);
			}

			// we still want to run any post
			// visit stuff that may be passed in
			if (post !is null) {
				post(stab);
			}
		});
		pop_defer_ctx();
	}

	Label build_block(kir.instr.Function current_func, ast.Block_Node block, Basic_Block b = null) {
		auto bb = b is null ? push_bb() : b;
		visit_block(block);
		return new Label(bb.name(), bb);
	}	

	Module_Info module_struct(Symbol_Table val) {
		string[] names;
		Type[] types;

		names.reserve(val.symbols.length);
		types.reserve(val.symbols.length);

		foreach (ref key, val; val.symbols) {
			names ~= key;
			// yeet
			types ~= curr_sym_table.env.conv_type(val.reference);
		}

		return new Module_Info(types, names);
	}

	void build_func(Function fn, ast.Block_Node func_body, Function_Parameter[] params) {
		auto entry = push_bb();

		// alloc all the params
		foreach (p; params) {
			auto param_alloc = new Alloc(curr_sym_table.env.conv_type(p.type), p.twine.lexeme);
			fn.params ~= param_alloc;
		}

		build_block(fn, func_body, entry);

		// if there are no instructions in the last basic
		// block add a return
		// OR if the last instruction is not a return!
		if (fn.curr_block.instructions.length == 0 || !is_branching_instr(fn.last_instr())) {
			fn.add_instr(new Return(new Void()));
		}
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
		// NOTE: we set the curr_func since it's
		// already been set in driver.d
		if (func.has_attribute("c_func")) {
			curr_func = ir_mod.c_funcs[func.name.lexeme];
		}
		else {
			curr_func = ir_mod.get_function(func.name.lexeme);
		}

		curr_func.set_attributes(func.get_attribs());

		// this is kinda hacky.
		bool is_proto = func.func_body is null;

		if (is_proto) return;

		build_func(curr_func, func.func_body, func.params);
	}

	// re-writes 
	// a += b into
	// a = a + b
	// i.e. 
	// a binary op and a store.
	Value build_incdec_shorthand(Type_Environment env, ast.Binary_Expression_Node binary) {
		Value lhs = build_expr(env, binary.left);
		Value rhs = build_expr(env, binary.right);

		// this is a hack but should work in most cases.
		// TODO/FIXME/NOTE: does not work for >>= and <<= but we havent
		// added those yet!
		char operand = binary.operand.lexeme[0];

		auto operation = new Binary_Op(lhs.get_type(), to!string(operand), lhs, rhs);
		return new Store(lhs.get_type(), lhs, operation);
	}

	Value build_binary_expr(Type_Environment env, ast.Binary_Expression_Node binary) {
		Value left = build_expr(env, binary.left);
		Value right = build_expr(env, binary.right);
		auto expr = new Binary_Op(left.get_type(), binary.operand, left, right);

		switch (binary.operand.lexeme) {
		// special inc/dec ops
		case "+=":
		case "-=":
		case "*=":
		case "/=":
			return build_incdec_shorthand(env, binary);

		// asign is a store.
		case "=":
			return new Store(left.get_type(), left, right);

		// fallthru
		default:
			break;
		}

		auto temp = new Alloc(left.get_type(), gen_temp());
		curr_func.add_instr(temp);

		auto store = new Store(left.get_type(), temp, expr);
		curr_func.add_instr(store);
		return new Identifier(temp.get_type(), temp.name);
	}

	Type get_sym_type_via(Type type, Symbol_Node sym) {
		string name = sym.value.lexeme;
		if (auto structure = cast(Structure) type) {
			return structure.get_field_type(name);
		}

		logger.fatal("unhandled lookup via " ~ to!string(type));
		assert(0);
	}

	Value build_sym_access_via(Type_Environment env, Value last, Symbol_Node sym) {
		if (auto identifier = cast(Identifier) last) {
			if (auto structure = cast(Structure) last.get_type()) {
				auto idx = structure.get_field_index(sym.value.lexeme);
				auto type_width = structure.types[idx].get_width();
				return new Get_Element_Pointer(identifier, idx, type_width);
			}
			else if (auto tuple = cast(Tuple) last.get_type()) {
				// TODO ensure that the symbol thing here is a number?
				int idx = to!int(sym.value.lexeme);
				auto type_width = tuple.types[idx].get_width();
				return new Get_Element_Pointer(identifier, idx, type_width);
			}
			else if (auto ptr = cast(Pointer) last.get_type()) {
				// TODO we need to handle accessing pointers
				// this is a little awkward.
				assert(0, "unhandled base type for pointer de-ref");
			}
			else {
				if (last.get_type() is null) {
					assert(0);
				}

				logger.fatal("what is " ~ to!string(last) ~ " " ~ to!string(last.get_type()));
				assert(0);
			}
		}
		else if (auto gep = cast(Get_Element_Pointer) last) {
			// how the fuck
			return gep;
		}

		logger.fatal("what is " ~ to!string(last));
		assert(0);
	}

	Value build_expr_via(Type_Environment env, Value last, ast.Expression_Node v) {
		if (auto call = cast(ast.Call_Node) v) {
			assert(0);
		}
		else if (auto sym = cast(ast.Symbol_Node) v) {
			return build_sym_access_via(env, last, sym);
		}

		writeln(last, " vs ", v, " types ", typeid(last), " vs ", typeid(v));
		assert(0);
	}

	// TODO make this work for EVERYTHING
	Value build_method_call(Type_Environment env, ast.Path_Expression_Node path) {
		writeln("build_method_call", path);

		Value last = null;
		foreach (ref v; path.values) {
			if (last !is null) {
				last = build_expr_via(env, last, v);			
			} 
			else {
				last = build_expr(env, v);
			}
		}
		return last;
	}

	Value build_sym_access(Type_Environment env, ast.Path_Expression_Node path) {
		Value last = null;
		foreach (ref idx, v; path.values) {
			if (last !is null) {
				last = build_expr_via(env, last, v);
			}
			else {
				last = build_expr(env, v);
			}
		}
		return last;
	}

	Value build_module_access(ast.Module_Access_Node man) {
		auto sym = cast(Symbol_Node) man.left;

		Module other = mod.edges[sym.value.lexeme];
		writeln("MOD ACCESS in ", other.name);

		Value right = build_expr(other.sym_tables.env, man.right);

		// FIXME not void.
		auto mod_name = new Identifier(right.get_type(), man.left.value.lexeme);

		// FIXME env is taken from module.
		return new Module_Access(mod_name, right);
	}

	Value build_path(Type_Environment env, ast.Path_Expression_Node path) {
		if (path.values.length == 1) {
			return build_expr(env, path.values[0]);
		}

		auto last = path.values[$-1];
		if (cast(ast.Call_Node) last) {
			return build_method_call(env, path);
		}
		else if (auto sym = cast(ast.Symbol_Node) last) {
			return build_sym_access(env, path);
		}
		else if (auto integer = cast(Integer_Constant_Node) last) {
			// again tuple hack!
			// FIXME an idea is to maybe
			// re-write an integer constant node
			// in the parser in a PATH to be a symbol node?
			path.values[$-1] = new Symbol_Node(integer.tok);
			return build_sym_access(env, path);
		}

		foreach (v; path.values) {
			writeln(v);
		}

		logger.error(path.get_tok_info().get_tok(), "build_path: unimplemented path node " ~ to!string(typeid(last)));
		assert(0);
	}

	Value build_index_expr(Type_Environment env, ast.Index_Expression_Node node) {
		Value addr = build_expr(env, node.array);
		Value sub = build_expr(env, node.index);
		writeln(node.array, " => ", addr, " is ", typeid(addr));
		return new Index(env.conv_type(node), addr, sub);
	}

	Value value_at(Type_Environment env, ast.Expression_Node e) {
		return new Deref(build_expr(env, e));
	}

	Value addr_of(Type_Environment env, ast.Expression_Node e) {
		return new Addr_Of(build_expr(env, e));
	}

	Value build_unary_expr(Type_Environment env, ast.Unary_Expression_Node unary) {
		static import keyword;

		// grammar.d
		// "+", "-", "!", "^", "@", "&"
		final switch (unary.operand.lexeme) {
		case "+":
		case "-":
		case "!":
		case "^":
			return new Unary_Op(unary.operand, build_expr(env, unary.value));
		case "@":
			return value_at(env, unary.value);
		case "&":
			return addr_of(env, unary.value);
		case keyword.Size_Of:
		case keyword.Len_Of:
		case keyword.Type_Of:
			return new Builtin(unary.operand, build_expr(env, unary.value));
		}
		assert(0, "unhandled build unary expr in builder.");
	}

	Value build_call(Type_Environment env, ast.Call_Node call) {
		Value left = build_expr(env, call.left);
		Value[] args;
		foreach (arg; call.args) {
			args ~= build_expr(env, arg);
		}

		// re-write identifier to function thing?

		return new Call(left.get_type(), left, args);
	}

	// TODO rename
	// this pushes a basic block which will join
	// with its predecessor IF the previous block
	// does not have a branching instruction
	Basic_Block push_bb(string namespace = "") {
		auto prev_block = curr_func.curr_block;
		auto new_block = curr_func.push_block(namespace);
		if (prev_block !is null) {
			if (!is_branching_instr(prev_block.last_instr())) {
				prev_block.add_instr(new Jump(new Label(new_block)).setfallthru);
			}
		}
		return new_block;
	}

	// pushes a block and doesn't connect it to anything
	// it is assumed the bb will be targetted later.
	Basic_Block push_target_bb(string namespace = "") {
		return curr_func.push_block(namespace);
	}

	// this is a specialize block thingy majig
	Value build_eval_expr(Type_Environment env, ast.Block_Expression_Node eval) {
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
		Alloc a = new Alloc(new Void(), bb.name() ~ "_" ~ gen_temp());
		curr_func.add_instr(a);

		build_block(curr_func, eval.block);

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

		// slice the quotes from the start
		// and end of the string.
		auto str_no_quotes = str.value[1..$-1];

		string const_ref = add_constant(new Constant(new CString(), str_no_quotes));
		auto string_data_ptr = new Constant_Reference(new CString(), const_ref);

		// c-style string is simply a raw unsigned
		// 8 bit integer pointer
		if (str.type == String_Type.C_STYLE) {
			return string_data_ptr;
		}

		// FIXME!

		// TODO we assume its pascal here..
		// pascal type is the pointer as well as the length of
		// the array as a struct.
		auto val = new Composite(get_string());
		val.add_value(new Constant(get_int(false, 64), to!string(str.value.length)));
		val.add_value(string_data_ptr);
		return val;
	}

	Value build_lambda(Type_Environment env, ast.Lambda_Node node) {
		auto name = mod.lambda_names[node];

		// type check...
		auto type = cast(Fn) env.lookup_type(name);

		writeln(name, " and type is ", type);

		auto fn = ir_mod.add_function(name, type.ret);

		auto prev_func = curr_func;
		{
			curr_func = fn;			// push
			build_func(fn, node.block, node.func_type.params);
			curr_func = prev_func;	// pop
		}

		return new Identifier(type, name);
	}

	Value build_expr(Type_Environment env, ast.Expression_Node expr) {
		if (auto integer_const = cast(Integer_Constant_Node) expr) {
			// FIXME
			return new Constant(get_int(true, 32), to!string(integer_const.value));
		}
		else if (auto float_const = cast(Float_Constant_Node) expr) {
			// FIXME
			return new Constant(get_float(64), to!string(float_const.value));
		}
		else if (auto rune_const = cast(Rune_Constant_Node) expr) {
			dchar c = to!dchar(rune_const.value);
			// runes are a 4 byte signed integer.
			return new Constant(get_rune(), to!string(to!uint(c)));
		}
		else if (auto index = cast(Index_Expression_Node) expr) {
			return build_index_expr(env, index);
		}
		else if (auto binary = cast(Binary_Expression_Node) expr) {
			return build_binary_expr(env, binary);
		}
		else if (auto paren = cast(Paren_Expression_Node) expr) {
			return build_expr(env, paren.value);
		}
		else if (auto path = cast(Path_Expression_Node) expr) {
			return build_path(env, path);
		}
		else if (auto man = cast(Module_Access_Node) expr) {
			return build_module_access(man);
		}
		else if (auto sym = cast(Symbol_Node) expr) {
			return new Identifier(env.conv_type(sym), sym.value.lexeme);
		}
		else if (auto cast_expr = cast(Cast_Expression_Node) expr) {
			// TODO float to int vice versa
			// or truncate to smaller type i.e. u32 to u8
			// for now just spit out the build expr
			return build_expr(env, cast_expr.left);
		}
		else if (auto call = cast(Call_Node) expr) {
			return build_call(env, call);
		}
		else if (auto unary = cast(Unary_Expression_Node) expr) {
			return build_unary_expr(env, unary);
		}
		else if (auto eval = cast(Block_Expression_Node) expr) {
			return build_eval_expr(env, eval);
		}
		else if (auto str_const = cast(String_Constant_Node) expr) {
			return build_string_const(str_const);
		}
		else if (auto bool_const = cast(Boolean_Constant_Node) expr) {
			string value = bool_const.value ? "1" : "0";
			return new Constant(get_int(false, 8), value);
		}
		else if (auto lambda = cast(Lambda_Node) expr) {
			return build_lambda(env, lambda);
		}

		logger.fatal("IR_Builder: unhandled build_expr ", to!string(expr), " -> ", to!string(typeid(expr)));
		assert(0);
	}

	void build_return_node(ast.Return_Statement_Node ret) {
		auto ret_instr = new Return(new Void());

		// its not a void type
		if (ret.value !is null) {
			ret_instr.set_type(curr_sym_table.env.conv_type(ret.value));
			ret_instr.results ~= build_expr(curr_sym_table.env, ret.value);
		}

		// TODO return values
		curr_func.add_instr(ret_instr);
	}

	If last_if = null;
	If last_else_if = null;

	/*
		TODO clean this function up

		if_stat_entry:
			fall
		
		check_a:
			...
			if cond then check_a_true else next_check
		check_a_true:
			jmp exit;									re-write

		check_b:
			if cond then check_b_true else exit
		check_b_true:
			jmp exit;									re-write

		else:
			...
			fallthrough

		exit:
	*/
	void build_if_node(ast.If_Statement_Node if_stat) {
		// a list of instructions which will
		// be re-written to jump to the end
		Jump[] jump_to_ends;

		auto if_entry = push_bb();
		Value condition = build_expr(curr_sym_table.env, if_stat.condition);

		If last_if = new If(condition);

		auto if_check = push_bb();
		curr_func.add_instr(last_if);

		last_if.a = build_block(curr_func, if_stat.block);

		// 		jump to exit rewrite
		jump_to_ends ~= cast(Jump) curr_func.add_instr(new Jump(null));

		// there is no else if chain so we need to generate
		// the else statement here _if necessary_ and hookup the
		// else, or jump to the exit.
		if (if_stat.else_ifs.length == 0) {
			// we have an else stat so generate it
			// and join it to this if
			if (if_stat.else_stat !is null) {
				auto else_bb = push_target_bb();
				last_if.b = build_block(curr_func, if_stat.else_stat.block);
	
				// 		jump to exit rewrite
				jump_to_ends ~= cast(Jump) curr_func.add_instr(new Jump(null));
			}
			// we dont have an else statement so we
			// jump to the exit. the easiest way to do this
			// is with another block that is joined to the prev.
			else {
				auto jte = push_target_bb();
				last_if.b = new Label(jte);

				// 		jump to exit rewrite
				jump_to_ends ~= cast(Jump) curr_func.add_instr(new Jump(null));
			}
		}
		else {
			while (if_stat.else_ifs.length > 0) {
				auto fst = if_stat.else_ifs[0];
				if_stat.else_ifs.popFront();

				// check_fst:
				auto check_fst = push_target_bb();

				// this is an else if we have to join together.
				if (last_if !is null) {
					last_if.b = new Label(check_fst);
				}

				//		if cond then check_fst_true else LABEL
				auto cond = build_expr(curr_sym_table.env, fst.condition);
				auto elif_jmp = new If(cond);
				curr_func.add_instr(elif_jmp);

				// check_fst_true:
				elif_jmp.a = build_block(curr_func, fst.block);

				// 		jump to exit rewrite
				jump_to_ends ~= cast(Jump) curr_func.add_instr(new Jump(null));

				// if we have else_ifs left over, we
				// set the last if to the if and re-write it
				// in the next iteration to jump false to the
				// iterations block.
				if (if_stat.else_ifs.length > 0) {
					last_if = elif_jmp;
				}
				else {
					// we have an else stat so generate it
					// and join it to this if
					if (if_stat.else_stat !is null) {
						auto else_bb = push_target_bb();
						elif_jmp.b = build_block(curr_func, if_stat.else_stat.block);
			
						// 		jump to exit rewrite
						jump_to_ends ~= cast(Jump) curr_func.add_instr(new Jump(null));
					}
					// we dont have an else statement so we
					// jump to the exit. the easiest way to do this
					// is with another block that is joined to the prev.
					else {
						auto jte = push_target_bb();
						elif_jmp.b = new Label(jte);

						// 		jump to exit rewrite
						jump_to_ends ~= cast(Jump) curr_func.add_instr(new Jump(null));
					}
				}
			}
		}

		auto exit = push_target_bb();
		foreach (re; jump_to_ends) {
			re.label = new Label(exit);
		}
	}

	/*
		loop node generates an ast.While_Statement_Node
		with a condition of a true boolean.
	*/
	void build_loop_node(ast.Loop_Statement_Node loop) {
		// TODO some nice api for generating AST stuff perhaps?

		// re-write a loop to a while(true)
		auto true_bool = new Boolean_Constant_Node(new Token("true", Token_Type.Identifier));
		auto while_node = new While_Statement_Node(true_bool, loop.block);
		build_while_loop_node(while_node);
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

	void build_next_node(ast.Next_Statement_Node n) {
		auto jmp_addr = curr_func.curr_block.instructions.length;
		curr_func.add_instr(new Jump(null));
		next_rewrites[curr_func.curr_block] = jmp_addr;
	}

	void build_break_node(ast.Break_Statement_Node b) {
		auto jmp_addr = curr_func.curr_block.instructions.length;

		auto last_instr = curr_func.curr_block.last_instr();

		// only add instr if its not a branching one
		if (!is_branching_instr(last_instr)) {
			curr_func.add_instr(new Jump(null));
		} 

		break_rewrites[curr_func.curr_block] = jmp_addr;
	}

	void analyze_global(ast.Variable_Statement_Node var) {
		// TODO what if there is no value assigned?
		// TODO make sure it's allocated... we can't really
		// introduce temporaries as a global...

		if (var.value is null) {
			assert("global no value unhandled");
		}

		Value v = build_expr(curr_sym_table.env, var.value);
		ir_mod.constants[var.twine.lexeme] = v;
	}

	override void analyze_var_stat_node(ast.Variable_Statement_Node var) {
		Type type = curr_sym_table.env.conv_type(var);
		
		if (curr_func is null) {
			// it's a global
			analyze_global(var);
			return;
		}

		// TODO handle global variables.
		auto addr = curr_func.add_alloc(new Alloc(type, var.twine.lexeme));

		// this handles setting the default initializer values.
		// clean me up!
		if (auto structure = cast(Structure) type) {
			foreach (index, value; structure.values) {
				auto val = build_expr(curr_sym_table.env, value);

				// FIXME?
				auto gep = new Get_Element_Pointer(new Identifier(type, var.twine.lexeme), index, val.get_type.get_width);
				curr_func.add_instr(new Store(val.get_type(), gep, val));
			}
		}

		if (var.value !is null) {
			auto val = build_expr(curr_sym_table.env, var.value);
			curr_func.add_instr(new Store(val.get_type(), addr, val));
		}
	}

	void build_for_loop_node(ast.For_Statement_Node loop) {
		auto loop_check = new Label(push_bb());
		Value v = build_expr(curr_sym_table.env, loop.condition);
		If jmp = new If(v);
		curr_func.add_instr(jmp);

		auto loop_body = new Label(push_bb());
		build_block(curr_func, loop.block, loop_body.reference);

		Value step = build_expr(curr_sym_table.env, loop.step);
		if (auto str = cast(Store) step) {
			curr_func.add_instr(str);
		}

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

	void build_while_loop_node(ast.While_Statement_Node loop) {
		auto loop_check = new Label(push_bb());
		Value v = build_expr(curr_sym_table.env, loop.condition);
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

	// deferred statements run at block level rather than
	// function level.
	void build_defer_node(ast.Defer_Statement_Node defer) {
		logger.verbose("registering defer ", to!string(defer));

		auto defer_ctx = curr_defer_ctx();
		defer_ctx.stat ~= defer.stat;
	}

	void build_yield(ast.Yield_Statement_Node yield) {
		logger.error(yield.get_tok_info(), "unhandled");
		assert(0);
	}

	void build_structure_destructure(ast.Structure_Destructuring_Statement_Node stat) {
		foreach (v; stat.values) {
			auto addr = curr_func.add_alloc(new Alloc(new Void(), v.lexeme));
		}
	}

	// FIXME
	// this is slow and expensive...
	// esp for multiple expressions
	// also its hard to read/understand
	// as it jumps all over the place.
	void build_match(ast.Switch_Statement_Node match) {
		Value cond = build_expr(curr_sym_table.env, match.condition);

		Jump[] jump_to_ends;

		If last_if = null;
		foreach (ref i, a; match.arms) {
			auto arm_start_bb = new Label(push_bb());

			If[] rewrite_jumpto_true;

			foreach (ref j, expr; a.expressions) {
				auto check = new Label(push_bb());

				// cond == val
				auto val = build_expr(curr_sym_table.env, expr);
				auto cmp = new Binary_Op(cond.get_type(), "==", cond, val);

				// gen temp
				string alloc_name = gen_temp();
				auto temp = new Alloc(cond.get_type(), alloc_name);
				curr_func.add_instr(temp);
				curr_func.add_instr(new Store(temp.get_type(), temp, cmp));

				If jmp = new If(new Identifier(temp.get_type(), alloc_name));
				curr_func.add_instr(jmp);

				if (last_if !is null) {
					last_if.b = check;
				}

				last_if = jmp;

				rewrite_jumpto_true ~= jmp;
			}

			auto arm_body = build_block(curr_func, a.block);
			jump_to_ends ~= cast(Jump) curr_func.add_instr(new Jump(null));

			foreach (ref iff; rewrite_jumpto_true) {
				iff.a = arm_body;
			}
		}

		auto match_end = new Label(push_bb());
		last_if.b = match_end;
		foreach (ref jte; jump_to_ends) {
			jte.label = match_end;
		}
	}

	override void visit_stat(ast.Statement_Node node) {
		Basic_Block block_sample = curr_func.curr_block;

		if (auto let = cast(ast.Variable_Statement_Node) node) {
			analyze_var_stat_node(let);
		}
		else if (auto yield = cast(ast.Yield_Statement_Node) node) {
			build_yield(yield);
		}
		else if (auto ret = cast(ast.Return_Statement_Node) node) {
			build_return_node(ret);
		}
		else if (auto defer = cast(ast.Defer_Statement_Node) node) {
			build_defer_node(defer);
		}
		
		else if (auto if_stat = cast(ast.If_Statement_Node) node) {
			build_if_node(if_stat);
		}
		else if (auto match = cast(ast.Switch_Statement_Node) node) {
			build_match(match);	
		}
		else if (auto structure_destructure = cast(ast.Structure_Destructuring_Statement_Node) node) {
			build_structure_destructure(structure_destructure);
		}
		else if (auto loop = cast(ast.Loop_Statement_Node) node) {
			build_loop_node(loop);
		}
		else if (auto loop = cast(ast.While_Statement_Node) node) {
			build_while_loop_node(loop);
		}
		else if (auto for_loop = cast(ast.For_Statement_Node) node) {
			build_for_loop_node(for_loop);
		}
		else if (auto b = cast(ast.Break_Statement_Node) node) {
			build_break_node(b);
		}
		else if (auto n = cast(ast.Next_Statement_Node) node) {
			build_next_node(n);
		}
		else if (auto e = cast(ast.Expression_Node) node) {
			auto v = build_expr(curr_sym_table.env, e);
			if (auto instr = cast(Instruction) v) {
				curr_func.add_instr(instr);
			}
		}
		else if (auto b = cast(ast.Block_Node) node) {
			build_block(curr_func, b);
		}
		else if (cast(ast.Else_If_Statement_Node) node) {
			assert(0);
		}
		else if (cast(ast.Else_Statement_Node) node) {
			assert(0);
		}
		else {
			logger.error(node.get_tok_info(), "unimplemented node '" ~ to!string(typeid(node)) ~ "':");
			assert(0);
		}

		if (block_sample.instructions.length == 0) {
			return;
		}

		auto last_instr = block_sample.instructions[$ - 1];
		last_instr.set_code(to!string(node));
	}

	IR_Module build(ref Module mod, AST as_tree) {
		this.mod = mod;
		foreach (node; as_tree) {
			super.process_node(node);
		}
		return ir_mod;
	}
}
