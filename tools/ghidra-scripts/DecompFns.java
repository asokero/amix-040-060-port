import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.*;
import ghidra.util.task.ConsoleTaskMonitor;
import ghidra.program.model.listing.*;
import java.util.List;
public class DecompFns extends GhidraScript {
  public void run() throws Exception {
    String fns = System.getenv("GH_FNS");
    DecompInterface dec = new DecompInterface();
    dec.openProgram(currentProgram);
    for (String name : fns.split(",")) {
      name = name.trim(); if (name.isEmpty()) continue;
      List<Function> matches = getGlobalFunctions(name);
      if (matches.isEmpty()) { println("=== NO FUNCTION named "+name+" ==="); continue; }
      Function fn = matches.get(0);
      DecompileResults res = dec.decompileFunction(fn, 120, new ConsoleTaskMonitor());
      println("@@@@ "+name+" @ "+fn.getEntryPoint()+" @@@@");
      if (res != null && res.decompileCompleted()) println(res.getDecompiledFunction().getC());
      else println("DECOMPILE FAILED");
    }
  }
}
