module tarjans_scc;

import std.algorithm.comparison : min;
import std.range.primitives : popBack, back;

import krug_module;
import dep_graph;

// uses tarjans algorithm to get the strongly
// connected components in our dependency graph.

alias SCC = Module[];

struct Tarjan {
	Module[] visited;
	bool[string] stack;
	int index = 0;
}

SCC[] get_scc(ref Dependency_Graph g) {
	SCC[] cycle_set;
	Tarjan tarjans;

	foreach (entry; g.byKeyValue()) {
		auto n = entry.value;
		if (n.index == -1) {
			SCC cycle = tarjans.strong_connect(entry.value);
			if (cycle.length > 1) {
				cycle_set ~= cycle;
			}
		}
	}

	return cycle_set;
}

SCC strong_connect(ref Tarjan t, Module m) {
	m.index = t.index;
	m.low_link = t.index;
	t.index += 1;

	t.visited ~= m;

	// FIXME use name here or what?
	t.stack[m.name] = true;

	Module[string] neighbours = m.edges;
	if (neighbours !is null) {
		foreach (entry; neighbours.byKeyValue()) {
			auto n = entry.value;
			if (n.index == -1) {
				t.strong_connect(n);
				m.low_link = min(m.low_link, n.low_link);
			}
			else if (n.name in t.stack) {
				m.low_link = min(m.low_link, n.index);
			}
		}

	}

	SCC cycle;
	if (m.low_link == m.index) {
		Module p = null;
		do {
			p = t.visited.back;
			t.visited.popBack();

			t.stack.remove(p.name);
			cycle ~= p;
		}
		while (p != m);
	}
	return cycle;
}
