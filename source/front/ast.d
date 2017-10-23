module ast;

import std.typecons;
import std.conv;
import std.bigint;

import scope_sys;
import krug_module;

// binding of an expression to a token
alias Binding = Tuple!(Token, "twine", Expression_Node, "value");

interface Semicolon_Stat {}

class Node {}

class Statement_Node : Node, Semicolon_Stat {}

class Named_Type : Statement_Node {
    Token twine;
    Type_Node type;

    this(Token twine, Type_Node type) {
        this.twine = twine;
        this.type = type;
    }
}

class Variable_Statement_Node : Statement_Node {
    Token twine;
    Type_Node type;
    Expression_Node value = null;
    bool mutable = false;

    this(Token twine, Type_Node type) {
        this.twine = twine;
        this.type = type;
    }
}

// CONSTNATS

class Constant_Node(T) : Expression_Node {
    Token tok;
    T value;

    this(Token tok, T value) {
        this.tok = tok;
        this.value = value;
    }
}

class String_Constant_Node : Constant_Node!string {
    this(Token tok) {
        super(tok, tok.lexeme);
    }
}

class Float_Constant_Node : Constant_Node!double {
    this(Token tok) {
        super(tok, to!double(tok.lexeme));
    }
}

class Integer_Constant_Node : Constant_Node!BigInt {
    this(Token tok) {
        super(tok, BigInt(tok.lexeme));
    }
}

class Boolean_Constant_Node : Constant_Node!bool {
    this(Token tok) {
        // TODO: what if token is something other
        // than "true"? this has to be validated before
        // we create the node.
        super(tok, tok.cmp("true") ? true : false);
    }
}

class Rune_Constant_Node : Constant_Node!dchar {
    this(Token tok) {
        super(tok, to!dchar(tok.lexeme[0]));
    }
}

// TOP LEVEL DECLARATION AST NODES

class Function_Node : Node {
    Token name;
    Type_Node return_type;
	Block_Node func_body;
}

class Block_Node : Node {
	Statement_Node[] statements;
	Function_Node parent;
	Scope block_scope;

	this() {

	}
}

// EXPRESSION AST NODES

class Expression_Node : Node {

}

class Binary_Expression_Node : Expression_Node {
	Expression_Node left, right;
	Token operand;

	this(Expression_Node left, Token operator, Expression_Node right) {
	    this.left = left;
	    this.operand = operator;
	    this.right = right;
	}
}

class Unary_Expression_Node : Expression_Node {
	Token operand;
	Expression_Node value;

	this(Token operand, Expression_Node value) {
	    this.operand = operand;
	    this.value = value;
	}
}

class Paren_Expression_Node : Expression_Node {
	Expression_Node value;

    this(Expression_Node value) {
        this.value = value;
    }
}

// TYPE AST NODES

class Type_Node : Node {}

class Primitive_Type_Node : Type_Node {
	Token type_name;

	this(Token type_name) {
		this.type_name = type_name;
	}
}

// complex types

class Array_Type_Node : Type_Node {
public:
	Type_Node base_type;
	Expression_Node value;

	this(Type_Node base_type, Expression_Node value = null) {
		this.base_type = base_type;
		this.value = value;
	}
}

class Slice_Type_Node : Type_Node {
public:
	Type_Node base_type;

	this(Type_Node base_type) {
		this.base_type = base_type;
	}
}

class Pointer_Type_Node : Type_Node {
public:
	Type_Node base_type;

	this(Type_Node base_type) {
		this.base_type = base_type;
	}
}

class Union_Type_Node : Type_Node {
public:
	Binding[string] fields;

	void add_field(Token name, Expression_Node value) {
		fields[name.lexeme] = Binding(name, value);
	}	
}

class Structure_Type_Node : Type_Node {
public:
	Binding[string] fields;

	void add_field(Token name, Expression_Node value) {
		fields[name.lexeme] = Binding(name, value);
	}
}

alias Function_Parameter = Tuple!(
	bool, "mutable", 
	Token, "twine",
	Type_Node, "type");

class Function_Type_Node : Type_Node {
public:
	Type_Node return_type;
	Function_Parameter[string] params;

	void add_param(Token twine, Type_Node type, bool mutable = false) {
		params[twine.lexeme] = Function_Parameter(mutable, twine, type);
	}

	void set_return_type(Type_Node return_type) {
		this.return_type = return_type;
	}
}

alias Trait_Attribute = Tuple!(
	Token, "twine",
	Function_Type_Node, "type");

class Trait_Type_Node : Type_Node {
public:
	Trait_Attribute[string] attributes;

	void add_attrib(Token name, Function_Type_Node func_type_node) {
		attributes[name.lexeme] = Trait_Attribute(name, func_type_node);
	}
}

// TODO tagged union node