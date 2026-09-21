/**
	Application entry point.

	Copyright: © 2013 rejectedsoftware e.K.
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module app;

import dub.commandline;

// Set output path and options for coverage reports
version (DigitalMars) version (D_Coverage)
{
	shared static this()
	{
		import core.runtime, std.file, std.path, std.stdio;
		dmd_coverSetMerge(true);
		auto path = buildPath(dirName(thisExePath()), "../cov");
		if (!path.exists)
			mkdir(path);
		dmd_coverDestPath(path);
	}
}

version (linux) {
	import dub.internal.describecache;
	alias MainFunc = extern(C) int function(char[][]);
	extern(C) int _d_run_main(int argc, char** argv, MainFunc mainFunc);

	extern(C) int main(int argc, char** argv) {
		const result = tryDescribeCache(argc, argv);
		if (result >= 0) return result;
		return _d_run_main(argc, argv, &dubMain);
	}

	private extern(C) int dubMain(char[][] args) {
		auto immutableArgs = cast(string[])args;
		startDescribeCache(immutableArgs);
		return runDubCommandLine(immutableArgs);
	}
} else {
	int main(string[] args) { return runDubCommandLine(args); }
}
