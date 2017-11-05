// scope is a keyword so we'll dump it in
// a module called range for now
module sema.range;

class Symbol {
	string name;
	
	this(string name) {
		this.name = name;
	}
}

class Scope {
	uint id;
	Scope outer;
	Symbol[string] symbols;

	this() {
		this.id = 0;
	}

	this(Scope outer) {
		this.outer = outer;
		this.id = outer.id + 1;
	}

	Symbol lookup_sym(string name) {
		for (Scope s = this; s !is null; s = s.outer) {
			if (name in s.symbols) {
				return s.symbols[name];
			}
		}
		return null;
	}

	// registers the given symbol, if the
	// symbol already exists it will be
	// returned from the symbol table in the scope.
	Symbol register_sym(Symbol s) {
		if (s.name in symbols) {
			return symbols[s.name];
		}
		symbols[s.name] = s;
		return null;
	}
}