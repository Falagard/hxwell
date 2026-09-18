package hx.well.macro;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;
import haxe.io.Path;
import haxe.macro.Expr.Field;
import haxe.macro.Context;
import haxe.Template;
import haxe.macro.Expr;
using StringTools;
using StringTools;
using hx.well.tools.FieldTools;

class TemplateMacro {
    private static var templateKeys:Array<String> = [];

    public static function build():Array<Field> {

        // haxelib libpath
        var process = new Process("haxelib", ["libpath", "hxwell"]);
        createTemplateData('${process.stdout.readLine()}/resources/views');

        // Program Path, Dominant
        createTemplateData('${Sys.getCwd()}/resources/views');

        var fields = Context.getBuildFields();

        var dataField:Field = fields.getFieldOrFail("data");

        // Create expressions for each template to populate the StringMap
        var dataExprs:Array<Expr> = [];


        for(templateKey in templateKeys) {
            var templateExpr:Expr = macro new Template(haxe.Resource.getString('template.' + $v{templateKey}));
            dataExprs.push(macro $v{templateKey} => $templateExpr);
        }

        // HLC-BOOT-MIGRATION-GC-SIGSEGV-S1: this field's initializer runs as part of this
        // module's static-init code (HLC folds every class's static-init into one giant
        // generated `fun$init` C function), and constructs one `new Template(...)` +
        // `haxe.Resource.getString(...)` allocation per embedded view file with nothing
        // guarding those allocations. A SIGSEGV was observed under hlc at process boot inside
        // exactly this path (hl_gc_alloc_gen -> hl_alloc_obj -> haxe_Resource_getString, from
        // this generated static-init function), with the faulting address decoding as raw
        // string character data rather than a real pointer -- the signature of a corrupted
        // allocation result. Guard the whole map construction with HlGcGuard, matching the
        // pattern already established in the host application's SqliteDatabaseService.hx.
        var mapLiteral:Expr = macro $a{dataExprs};
        // Decide the guard at macro-generation time via Context.defined("hl") rather than an
        // #if hl inside the reified block, to avoid any ambiguity about when that preprocessor
        // directive would be evaluated relative to macro-vs-target compilation.
        // No `finally` in Haxe (see host application's CLAUDE.md convention) -- an exception
        // from inside the guarded span must still restore the guard before propagating, since
        // it is a process-global toggle and a leaked disable() would wedge the whole process.
        var guardedInit:Expr = Context.defined("hl")
            ? (macro {
                var __hxwellTemplateData:Map<String, Template>;
                hlgcguard.HlGcGuard.disable();
                try {
                    __hxwellTemplateData = $mapLiteral;
                    hlgcguard.HlGcGuard.restore();
                } catch (__hxwellGcE:Dynamic) {
                    hlgcguard.HlGcGuard.restore();
                    throw __hxwellGcE;
                }
                __hxwellTemplateData;
            })
            : mapLiteral;

        // Add create exprs into data field.
        dataField.kind = FieldType.FVar(macro:Map<String, Template>, guardedInit);

        return fields;
    }

    private static function createTemplateData(path:String, rootPath:String = null):Void {
        if(rootPath == null)
            rootPath = path;

        // Recursively add resources from the specified path
        path = Path.normalize(path);
        rootPath = Path.normalize(rootPath);
        var files = FileSystem.readDirectory(path);
        for (file in files) {
            var fullPath = path + "/" + file;
            if (FileSystem.isDirectory(fullPath)) {
                createTemplateData(fullPath, rootPath);
            } else {
                if(!fullPath.endsWith(".mtt.html"))
                {
                    trace(fullPath);
                    continue;
                }

                // Add the file as a resource
                var simplePath = fullPath.substring(rootPath.length + 1).replace("/", ".");
                simplePath = simplePath.substring(0, simplePath.length - ".mtt.html".length);

                if(!templateKeys.contains(simplePath))
                    templateKeys.push(simplePath);
                haxe.macro.Context.addResource('template.${simplePath}', File.getBytes(fullPath));
            }
        }
    }
}
