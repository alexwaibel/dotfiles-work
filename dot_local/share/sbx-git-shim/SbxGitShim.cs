using System;
using System.Diagnostics;
using System.Linq;
using System.Text;

public static class SbxGitShim
{
    private static string Quote(string value)
    {
        if (value.Length > 0 && value.All(character =>
            !char.IsWhiteSpace(character) && character != '"'))
        {
            return value;
        }

        var result = new StringBuilder("\"");
        var backslashes = 0;
        foreach (var character in value)
        {
            if (character == '\\')
            {
                backslashes++;
                continue;
            }
            if (character == '"')
            {
                result.Append('\\', backslashes * 2 + 1);
                result.Append(character);
                backslashes = 0;
                continue;
            }
            result.Append('\\', backslashes);
            backslashes = 0;
            result.Append(character);
        }
        result.Append('\\', backslashes * 2);
        result.Append('"');
        return result.ToString();
    }

    public static int Main(string[] args)
    {
        for (var index = 1; index < args.Length; index++)
        {
            if (args[index - 1] == "-c" && args[index] == "core.hooksPath=")
            {
                args[index] = "core.hooksPath=NUL";
            }
        }

        var process = Process.Start(new ProcessStartInfo
        {
            FileName = @"C:\Program Files\Git\cmd\git.exe",
            Arguments = string.Join(" ", args.Select(Quote)),
            UseShellExecute = false
        });
        process.WaitForExit();
        return process.ExitCode;
    }
}
