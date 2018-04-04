module kargs.run;

import std.datetime.stopwatch : StopWatch;
import std.stdio;
import std.datetime;
import std.format;
import std.conv;
import std.array;
import std.algorithm.sorting;
import std.parallelism;
import std.getopt;
import std.string;

import compiler_error : DEPENDENCY_CYCLE;

import kargs.command;
import cflags;
import colour;
import tarjans_scc;
import dependency_scanner;
import krug_module;
import diag.engine;
import logger;
import kargs.command;

import kir.cfg;
import kir.cfg_builder;

import parse.parser;
import ast;
import logger;

import kir.ir_mod;
import kir.ir_verify;
import kir.builder;

import gen.kurby.opcode;

import sema.analyzer;

import opt.opt_manager;

import gen.code_gen;
import gen.target;

// TODO: clean this up because
// this is pretty much a copy paste
// of the build command but with
// a different function call haha
class Run_Command : Command {
	Target BUILD_TARGET = Target.KURBY;

	this() {
		super("run", "compiles and runs the given krug program");
	}

	override void process(string[] args) {
		StopWatch rt_timer;
		rt_timer.start();

		if (args.length == 0) {
			logger.Error("No input files.");
			return;
		}

		getopt(args, 
			"verbose|v", &VERBOSE_LOGGING,
			"arch", &ARCH,
			"release|r", &RELEASE_MODE,
			"opt|O", &OPTIMIZATION_LEVEL,
			"out|o", &OUT_NAME,
		);

		debug {
			writeln("KRUG COMPILER, VERSION ", VERSION);
			writeln("* Executing compiler, optimization level O", to!string(OPTIMIZATION_LEVEL));
			writeln("* Operating system: ", os_name());
			writeln("* Architecture: ", arch_type());
			writeln("* Target Architecture: ", BUILD_TARGET);
			writeln("* Compiler is in ", (RELEASE_MODE ? "release" : "debug"), " mode");
			writeln();
		}

		string entry_file = args[0];
		auto main_source_file = new Source_File(entry_file);
		Krug_Project proj = build_krug_project(main_source_file);

		// run tarjan's strongly connected components
		// algorithm on the graph of the project to ensure
		// there are no cycles in the krug project graph

		logger.VerboseHeader("Cycle detection:");		
		SCC[] cycles = proj.graph.get_scc();
		if (cycles.length > 0) {
			foreach (cycle; cycles) {
				string dep_string;
				foreach (idx, mod; cycle) {
					if (idx > 0) {
						dep_string ~= " ";
					}
					dep_string ~= "'" ~ mod.name ~ "'";
				}

				// TODO a better error message for this.
				Diagnostic_Engine.throw_custom_error(DEPENDENCY_CYCLE,
						"There is a cycle in the project dependencies: " ~
						dep_string);
			}

			// let's not continue with compilation!
			return;
		}

		// TODO: we can move flatten -> sort into
		// one thing instead of a two step solution!

		// flatten the dependency graph into an array
		// of modules.
		Dependency_Graph graph = proj.graph;
		Module[] flattened;
		foreach (ref mod; graph) {
			flattened ~= mod;
		}

		// sort the flattened modules such that the
		// modules with the least amount of dependencies
		// are first
		auto sorted_modules = flattened.sort!((a, b) => a.dep_count() < b.dep_count());
		logger.VerboseHeader("Parsing:");
		foreach (ref mod; sorted_modules) {
			foreach (ref entry; mod.token_streams.byKeyValue) {
				logger.Verbose("- " ~ mod.name ~ "::" ~ entry.key);

				// there is no point starting a parser instance
				// if we have no tokens to parse!

				auto token_stream = entry.value;
				if (token_stream.length == 0) {
					mod.as_trees[entry.key] = [];
					continue;
				}

				mod.as_trees[entry.key] = new Parser(token_stream).parse();
			}
		}

		const auto parse_errors = logger.get_err_count();
		if (parse_errors > 0) {
			logger.Error("Terminating compilation: ", to!string(parse_errors),
					" parse errors encountered.");
			return;
		}

		logger.VerboseHeader("Semantic Analysis: ");
		foreach (ref mod; sorted_modules) {
			auto sema = new Semantic_Analysis(graph);
			foreach (ref sub_mod_name, as_tree; mod.as_trees) {
				sema.process(mod, as_tree);
			}
		}

		const auto sema_errors = logger.get_err_count();
		if (sema_errors > 0) {
			logger.Error("Terminating compilation: ", to!string(sema_errors),
					" semantic errors encountered.");
			return;
		}

		bool GEN_IR = true;
		if (!GEN_IR) return;

		Kir_Module[] krug_program;

		logger.VerboseHeader("Generating Krug IR:");
		foreach (ref mod; sorted_modules) {
			foreach (ref sub_mod_name, as_tree; mod.as_trees) {
				auto kir_builder = new Kir_Builder(mod.name, sub_mod_name);

				logger.Verbose(" - ", mod.name, "::", sub_mod_name);

				auto ir_mod = kir_builder.build(mod, as_tree);
				ir_mod.dump();
				new IR_Verifier(ir_mod);

				krug_program ~= ir_mod;
			}
		}

		logger.VerboseHeader("Control flow analysis of Krug IR:");
		foreach (mod; krug_program) {
			build_graphs(mod);
		}

		logger.VerboseHeader("Optimisation Pass: ");
		optimise(krug_program, OPTIMIZATION_LEVEL);

		logger.VerboseHeader("ByteCode Generation: ");
		generate_code(BUILD_TARGET, krug_program);

		auto rt_dur = rt_timer.peek();
		logger.Info("Program execution took ",
				to!string(rt_dur.total!"msecs"),
				"/ms or ", to!string(rt_dur.total!"usecs"), "/µs");
	}
}
