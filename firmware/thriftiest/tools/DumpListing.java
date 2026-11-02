// Ghidra headless post-script: 80251 source-mode listing of a Thriftiest Cam image. See docs/THRIFTIEST-FIRMWARE-ANALYSIS.md.
// args: OUT.txt SRCMODE(1)
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.*;
import ghidra.program.model.address.*;
import java.io.*;
public class DumpListing extends GhidraScript {
  public void run() throws Exception {
    String out = getScriptArgs()[0];
    AddressSpace sp = currentProgram.getAddressFactory().getDefaultAddressSpace();
    ghidra.program.model.lang.Register r = currentProgram.getRegister("srcMode");
    currentProgram.getProgramContext().setValue(r, sp.getAddress(0x800000), sp.getAddress(0x81b470), java.math.BigInteger.valueOf(Integer.parseInt(getScriptArgs()[1])));
    disassemble(sp.getAddress(0x800000));
    analyzeAll(currentProgram);
    try (PrintWriter w = new PrintWriter(new FileWriter(out))) {
      Listing l = currentProgram.getListing();
      for (Function f : l.getFunctions(true)) w.println("FUNC " + f.getEntryPoint() + " " + f.getName());
      InstructionIterator it = l.getInstructions(true);
      while (it.hasNext()) { Instruction i = it.next();
        w.println(i.getAddress() + "  " + i.toString()); }
      for (Function f : l.getFunctions(true)) { var refs = getReferencesTo(f.getEntryPoint()); w.println("XREF " + f.getEntryPoint() + " n=" + refs.length); }
    }
  }
}
