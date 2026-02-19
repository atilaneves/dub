/**
    Generator for Ninja build scripts

    Copyright: © 2026
    License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
*/
module dub.generators.ninja;

import dub.generators.generator;
import dub.internal.vibecompat.core.file;
import dub.internal.logging;
import dub.project;

import std.array : appender;

class NinjaGenerator : ProjectGenerator
{
    this(Project project)
    {
        super(project);
    }

    override void generateTargets(GeneratorSettings settings, in TargetInfo[string] targets)
    {
        const root = targets[m_project.rootPackage.name];
        const buildType = settings.buildType.length ? settings.buildType : "debug";
        const config = settings.config.length ? settings.config : root.config;
        const targetPath = root.buildSettings.targetPath.length ? root.buildSettings.targetPath : ".";
        const targetName = root.buildSettings.targetName.length ? root.buildSettings.targetName : m_project.rootPackage.name;
        const output = (NativePath(targetPath) ~ targetName).toNativeString();

        auto script = appender!(char[])();
        script.put("rule dub_build\n");
        script.put("  command = dub build");
        script.put(" --build=");
        script.put(buildType);
        script.put(" --config=");
        script.put(config);
        script.put("\n");
        script.put("  description = Building via dub\n");
        script.put("build ");
        script.put(output);
        script.put(": dub_build\n");
        script.put("default ");
        script.put(output);
        script.put("\n");

        const ninjaPath = m_project.rootPackage.path ~ "build.ninja";
        ninjaPath.writeFile(script.data);
        logInfo("Generated", Color.green, "build.ninja");
    }
}
