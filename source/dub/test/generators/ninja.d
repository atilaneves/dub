/*******************************************************************************

    Generator tests for Ninja

*******************************************************************************/

module dub.test.generators.ninja;

version (unittest):

version(Posix) unittest
{
    import dub.compilers.compiler : getCompiler;
    import dub.dub : Dub;
    import dub.generators.generator : GeneratorSettings;
    import std.exception : enforce;
    import std.file : exists, mkdirRecurse, rmdirRecurse, write;
    import std.path : absolutePath, buildPath;
    import std.process : Config, ProcessException, execute;
    import std.stdio : stderr;

    immutable projectDir = "dubtest/ninja-step1".absolutePath;
    const sourceDir = buildPath(projectDir, "source");

    if (exists(projectDir))
        rmdirRecurse(projectDir);
    mkdirRecurse(sourceDir);
    scope(exit) if (exists(projectDir)) rmdirRecurse(projectDir);

    write(buildPath(projectDir, "dub.json"), `{"name":"adder","targetType":"executable"}`);
    write(buildPath(sourceDir, "app.d"), q"EOS
int main(string[] args) {
    import std.conv: to;
    return args[1].to!int + args[2].to!int;
}
EOS");

    try
        enforce(execute(["ninja", "--version"]).status == 0);
    catch (ProcessException) {
        stderr.writeln("Warning: Ninja is not installed; skipping dub.test.generators.ninja.");
        return;
    }

    scope dub = new Dub(projectDir);
    dub.loadPackage();

    GeneratorSettings settings;
    const compilerBinary = dub.defaultCompiler;
    settings.compiler = getCompiler(compilerBinary);
    settings.platform = settings.compiler.determinePlatform(
        settings.buildSettings, compilerBinary, dub.defaultArchitecture);
    settings.config = "application";
    settings.buildType = "debug";
    dub.generateProject("ninja", settings);

    const buildResult = execute(["ninja"], null, Config.none, ulong.max, projectDir);
    enforce(buildResult.status == 0, buildResult.output);

    const binary = buildPath(projectDir, "adder");
    const run1 = execute([binary, "1", "2"], null, Config.none, ulong.max, projectDir);
    assert(run1.status == 3, run1.output);

    const run2 = execute([binary, "2", "3"], null, Config.none, ulong.max, projectDir);
    assert(run2.status == 5, run2.output);
}
