#![allow(dead_code)]

use crate::ast::*;
use std::collections::HashMap;

pub struct CodeGen {
    output: String,
    indent: usize,
    var_types: HashMap<String, String>,
    type_fields: HashMap<String, Vec<String>>,  // type name -> field names
    enum_names: Vec<String>,                     // known enum type names
}

impl CodeGen {
    pub fn new() -> Self {
        CodeGen {
            output: String::new(),
            indent: 0,
            var_types: HashMap::new(),
            type_fields: HashMap::new(),
            enum_names: Vec::new(),
        }
    }

    // ── Emit helpers ──

    fn emit(&mut self, s: &str) {
        self.output.push_str(s);
    }

    fn emit_indent(&mut self) {
        for _ in 0..self.indent {
            self.output.push_str("  ");
        }
    }

    fn emit_line(&mut self, s: &str) {
        self.emit_indent();
        self.output.push_str(s);
        self.output.push('\n');
    }

    // ── Type mapping ──

    fn type_to_c(&self, t: &TypeExpr) -> String {
        match t {
            TypeExpr::Named(name) => match name.as_str() {
                "int" | "int64" => "int64_t",
                "int8" => "int8_t",
                "int16" => "int16_t",
                "int32" => "int32_t",
                "uint" | "uint64" => "uint64_t",
                "uint8" | "byte" => "uint8_t",
                "uint16" => "uint16_t",
                "uint32" => "uint32_t",
                "float" | "float64" => "double",
                "float32" => "float",
                "bool" => "bool",
                "string" => "const char*",
                "natural" => "uint64_t",
                "rune" => "int32_t",
                other => other,
            }.to_string(),
            TypeExpr::Generic { name, args } => {
                let args_str = args.iter()
                    .map(|a| self.type_to_c(a))
                    .collect::<Vec<_>>()
                    .join("_");
                format!("{}_{}", name, args_str)
            }
            _ => "void".to_string(),
        }
    }

    fn is_string_type(&self, name: &str) -> bool {
        self.var_types.get(name).map(|t| t == "const char*").unwrap_or(false)
    }

    fn printf_format(&self, expr: &Expr) -> (&'static str, bool) {
        match expr {
            Expr::StringLit(_) | Expr::StringInterp { .. } => ("%s", false),
            Expr::FloatLit(_) => ("%f", false),
            Expr::BoolLit(_) => ("%d", false),
            Expr::Ident(name) if self.is_string_type(name) => ("%s", false),
            _ => ("%lld", true), // needs (long long) cast
        }
    }

    // ── C string escaping ──

    fn escape_c_string(s: &str) -> String {
        let mut out = String::with_capacity(s.len());
        for ch in s.chars() {
            match ch {
                '\n' => out.push_str("\\n"),
                '\t' => out.push_str("\\t"),
                '\\' => out.push_str("\\\\"),
                '"' => out.push_str("\\\""),
                '%' => out.push_str("%%"),
                c => out.push(c),
            }
        }
        out
    }

    // ── Params formatting ──

    fn format_params(&self, params: &[Param]) -> String {
        if params.is_empty() {
            "void".to_string()
        } else {
            params.iter()
                .map(|p| format!("{} {}", self.type_to_c(&p.type_ann), p.name))
                .collect::<Vec<_>>()
                .join(", ")
        }
    }

    // ── Main entry ──

    pub fn generate(&mut self, stmts: &[Stmt]) -> String {
        self.emit("#include <stdio.h>\n");
        self.emit("#include <stdint.h>\n");
        self.emit("#include <stdbool.h>\n");
        self.emit("#include <string.h>\n");
        self.emit("#include <stdlib.h>\n\n");

        // Forward declarations
        let decls: Vec<String> = stmts.iter().filter_map(|s| {
            if let Stmt::FnDecl { name, params, return_type, .. } = s {
                let ret = return_type.as_ref().map(|t| self.type_to_c(t)).unwrap_or_else(|| "void".to_string());
                Some(format!("{} {}({});", ret, name, self.format_params(params)))
            } else {
                None
            }
        }).collect();

        for decl in &decls {
            self.emit(decl);
            self.emit("\n");
        }
        if !decls.is_empty() { self.emit("\n"); }

        // Types and enums first
        for stmt in stmts {
            if matches!(stmt, Stmt::TypeDecl { .. } | Stmt::EnumDecl { .. }) {
                self.gen_stmt(stmt);
                self.emit("\n");
            }
        }

        // Functions second
        let mut top_level = Vec::new();
        for stmt in stmts {
            match stmt {
                Stmt::FnDecl { .. } => {
                    self.gen_stmt(stmt);
                    self.emit("\n");
                }
                Stmt::TypeDecl { .. } | Stmt::EnumDecl { .. } => {} // already emitted
                _ => top_level.push(stmt),
            }
        }

        if !top_level.is_empty() {
            self.emit("int main(void) {\n");
            self.indent += 1;
            for stmt in &top_level {
                self.gen_stmt(stmt);
            }
            self.emit_line("return 0;");
            self.indent -= 1;
            self.emit("}\n");
        }

        std::mem::take(&mut self.output)
    }

    // ── Statement codegen ──

    fn gen_stmt(&mut self, stmt: &Stmt) {
        match stmt {
            Stmt::LetDecl { name, type_ann, value }
            | Stmt::VarDecl { name, type_ann, value } => {
                self.gen_var_decl(name, type_ann, value);
            }
            Stmt::ConstDecl { name, value, .. } => {
                let c_type = self.infer_c_type(value);
                self.var_types.insert(name.clone(), c_type.clone());
                self.emit_indent();
                self.emit(&format!("const {} {} = ", c_type, name));
                self.gen_expr(value);
                self.emit(";\n");
            }
            Stmt::Assign { target, value } => {
                self.emit_indent();
                self.gen_expr(target);
                self.emit(" = ");
                self.gen_expr(value);
                self.emit(";\n");
            }
            Stmt::ResultAssign { value } => {
                self.emit_indent();
                self.emit("__result = ");
                self.gen_expr(value);
                self.emit(";\n");
            }
            Stmt::FnDecl { name, params, return_type, body, .. } => {
                self.gen_fn(name, params, return_type, body);
            }
            Stmt::If { branches, else_body } => {
                self.gen_if(branches, else_body);
            }
            Stmt::While { condition, body, label } => {
                self.gen_while(condition, body, label);
            }
            Stmt::For { var, iter, body, label, .. } => {
                self.gen_for(var, iter, body, label);
            }
            Stmt::Break(label) => {
                match label {
                    Some(lbl) => self.emit_line(&format!("goto {}_end;", lbl)),
                    None => self.emit_line("break;"),
                }
            }
            Stmt::Continue(label) => {
                match label {
                    Some(lbl) => self.emit_line(&format!("goto {}_start;", lbl)),
                    None => self.emit_line("continue;"),
                }
            }
            Stmt::Return => self.emit_line("return __result;"),
            Stmt::ExprStmt(expr) => {
                self.emit_indent();
                self.gen_expr(expr);
                self.emit(";\n");
            }
            Stmt::TypeDecl { name, fields, .. } => self.gen_type_decl(name, fields),
            Stmt::EnumDecl { name, variants, .. } => self.gen_enum_decl(name, variants),
            Stmt::Case { expr, branches, else_body } => self.gen_case(expr, branches, else_body),
            Stmt::Discard => self.emit_line("(void)0;"),
            _ => self.emit_line("/* not yet implemented */"),
        }
    }

    fn gen_var_decl(&mut self, name: &str, type_ann: &Option<TypeExpr>, value: &Option<Expr>) {
        let c_type = if let Some(t) = type_ann {
            self.type_to_c(t)
        } else if let Some(val) = value {
            self.infer_c_type(val)
        } else {
            "int64_t".to_string()
        };
        self.var_types.insert(name.to_string(), c_type.clone());
        self.emit_indent();
        self.emit(&format!("{} {} = ", c_type, name));
        if let Some(val) = value {
            self.gen_expr(val);
        } else {
            self.emit("0");
        }
        self.emit(";\n");
    }

    fn gen_fn(&mut self, name: &str, params: &[Param], return_type: &Option<TypeExpr>, body: &[Stmt]) {
        let ret = return_type.as_ref().map(|t| self.type_to_c(t)).unwrap_or_else(|| "void".to_string());
        let has_return = return_type.is_some();
        let params_str = self.format_params(params);

        self.emit(&format!("{} {}({}) {{\n", ret, name, params_str));
        self.indent += 1;

        if has_return {
            self.emit_line(&format!("{} __result;", ret));
        }

        for s in body { self.gen_stmt(s); }

        if has_return {
            self.emit_line("return __result;");
        }

        self.indent -= 1;
        self.emit("}\n");
    }

    fn gen_if(&mut self, branches: &[(Expr, Vec<Stmt>)], else_body: &Option<Vec<Stmt>>) {
        for (i, (cond, body)) in branches.iter().enumerate() {
            self.emit_indent();
            self.emit(if i == 0 { "if (" } else { "else if (" });
            self.gen_expr(cond);
            self.emit(") {\n");
            self.indent += 1;
            for s in body { self.gen_stmt(s); }
            self.indent -= 1;
            self.emit_indent();
            self.emit("} ");
        }
        if let Some(body) = else_body {
            self.emit("else {\n");
            self.indent += 1;
            for s in body { self.gen_stmt(s); }
            self.indent -= 1;
            self.emit_indent();
            self.emit("}");
        }
        self.emit("\n");
    }

    fn gen_while(&mut self, condition: &Expr, body: &[Stmt], label: &Option<String>) {
        if let Some(lbl) = label {
            self.emit_line(&format!("{}_start:", lbl));
        }
        self.emit_indent();
        self.emit("while (");
        self.gen_expr(condition);
        self.emit(") {\n");
        self.indent += 1;
        for s in body { self.gen_stmt(s); }
        self.indent -= 1;
        self.emit_line("}");
        if let Some(lbl) = label {
            self.emit_line(&format!("{}_end: ;", lbl));
        }
    }

    fn gen_for(&mut self, var: &str, iter: &Expr, body: &[Stmt], label: &Option<String>) {
        if let Some(lbl) = label {
            self.emit_line(&format!("{}_start:", lbl));
        }
        match iter {
            Expr::Range { start, end, inclusive } => {
                self.emit_indent();
                self.emit(&format!("for (int64_t {} = ", var));
                self.gen_expr(start);
                self.emit(&format!("; {} {} ", var, if *inclusive { "<=" } else { "<" }));
                self.gen_expr(end);
                self.emit(&format!("; {}++) {{\n", var));
            }
            _ => {
                self.emit_indent();
                self.emit(&format!("/* for {} in <collection> */ {{\n", var));
            }
        }
        self.indent += 1;
        for s in body { self.gen_stmt(s); }
        self.indent -= 1;
        self.emit_line("}");
        if let Some(lbl) = label {
            self.emit_line(&format!("{}_end: ;", lbl));
        }
    }

    fn gen_type_decl(&mut self, name: &str, fields: &[TypeField]) {
        self.type_fields.insert(
            name.to_string(),
            fields.iter().map(|f| f.name.clone()).collect(),
        );
        self.emit("typedef struct {\n");
        self.indent += 1;
        for f in fields {
            let c_type = self.type_to_c(&f.type_ann);
            self.emit_line(&format!("{} {};", c_type, f.name));
        }
        self.indent -= 1;
        self.emit(&format!("}} {};\n", name));
    }

    fn gen_enum_decl(&mut self, name: &str, variants: &[EnumVariant]) {
        self.enum_names.push(name.to_string());

        let has_data = variants.iter().any(|v| matches!(v.value, Some(EnumValue::Fields(_))));
        if has_data {
            self.emit_line(&format!("/* ADT {} — not yet implemented */", name));
            return;
        }

        self.gen_simple_enum(name, variants);
        self.gen_enum_to_string(name, variants);
    }

    fn gen_simple_enum(&mut self, name: &str, variants: &[EnumVariant]) {
        self.emit("typedef enum {\n");
        self.indent += 1;
        let last = variants.len().saturating_sub(1);
        for (i, v) in variants.iter().enumerate() {
            self.emit_indent();
            self.emit(&format!("{}_{}", name, v.name));
            if let Some(EnumValue::Int(n)) = &v.value {
                self.emit(&format!(" = {}", n));
            }
            if i < last { self.emit(","); }
            self.emit("\n");
        }
        self.indent -= 1;
        self.emit(&format!("}} {};\n", name));
    }

    fn gen_enum_to_string(&mut self, name: &str, variants: &[EnumVariant]) {
        let has_strings = variants.iter().any(|v| matches!(v.value, Some(EnumValue::String(_))));
        if !has_strings { return; }

        self.emit(&format!("const char* {}_to_string({} v) {{\n", name, name));
        self.indent += 1;
        self.emit_line("switch (v) {");
        self.indent += 1;
        for v in variants {
            let display = match &v.value {
                Some(EnumValue::String(s)) => s.as_str(),
                _ => &v.name,
            };
            self.emit_line(&format!("case {}_{}: return \"{}\";", name, v.name, display));
        }
        self.emit_line("default: return \"unknown\";");
        self.indent -= 1;
        self.emit_line("}");
        self.indent -= 1;
        self.emit("}\n");
    }

    fn gen_case(&mut self, expr: &Expr, branches: &[CaseBranch], else_body: &Option<Vec<Stmt>>) {
        self.emit_indent();
        self.emit("switch (");
        self.gen_expr(expr);
        self.emit(") {\n");
        self.indent += 1;

        for branch in branches {
            self.gen_case_label(&branch.pattern);
            self.indent += 1;
            for s in &branch.body { self.gen_stmt(s); }
            self.emit_line("break;");
            self.indent -= 1;
        }

        if let Some(body) = else_body {
            self.emit_line("default:");
            self.indent += 1;
            for s in body { self.gen_stmt(s); }
            self.emit_line("break;");
            self.indent -= 1;
        }

        self.indent -= 1;
        self.emit_line("}");
    }

    fn gen_case_label(&mut self, pattern: &CasePattern) {
        match pattern {
            CasePattern::Variant(name) => {
                // Color.red → Color_red in C
                let c_name = name.replace('.', "_");
                self.emit_line(&format!("case {}:", c_name));
            }
            // Ok/Error/Some/None require runtime type info — not yet implemented
            _ => self.emit_line("/* pattern not yet implemented */"),
        }
    }

    // ── Expression codegen ──

    fn gen_expr(&mut self, expr: &Expr) {
        match expr {
            Expr::IntLit(n) => self.emit(&n.to_string()),
            Expr::FloatLit(n) => self.emit(&n.to_string()),
            Expr::StringLit(s) => {
                self.emit("\"");
                self.emit(&Self::escape_c_string(s));
                self.emit("\"");
            }
            Expr::RuneLit(c) => self.emit(&format!("'{}'", c)),
            Expr::BoolLit(b) => self.emit(if *b { "true" } else { "false" }),
            Expr::Ident(name) => self.emit(name),
            Expr::Binary { left, op, right } => {
                self.emit("(");
                self.gen_expr(left);
                self.emit(match op {
                    BinOp::Add => " + ", BinOp::Sub => " - ",
                    BinOp::Mul => " * ", BinOp::Div => " / ", BinOp::Mod => " % ",
                    BinOp::Eq => " == ", BinOp::NotEq => " != ",
                    BinOp::Less => " < ", BinOp::LessEq => " <= ",
                    BinOp::Greater => " > ", BinOp::GreaterEq => " >= ",
                    BinOp::And => " && ", BinOp::Or => " || ",
                    BinOp::Pipe => " | ",
                });
                self.gen_expr(right);
                self.emit(")");
            }
            Expr::Unary { op, expr } => {
                self.emit(match op { UnaryOp::Neg => "-", UnaryOp::Not => "!" });
                self.gen_expr(expr);
            }
            Expr::Call { func, args } => {
                if let Expr::Ident(name) = func.as_ref() {
                    if name == "echo" { return self.gen_echo(args); }
                    // Struct constructor: Point(10, 20) → (Point){.x = 10, .y = 20}
                    if let Some(fields) = self.type_fields.get(name).cloned() {
                        self.emit(&format!("({}){{", name));
                        for (i, arg) in args.iter().enumerate() {
                            if i > 0 { self.emit(", "); }
                            if let Some(fname) = arg.name.as_ref() {
                                self.emit(&format!(".{} = ", fname));
                            } else if let Some(fname) = fields.get(i) {
                                self.emit(&format!(".{} = ", fname));
                            }
                            self.gen_expr(&arg.value);
                        }
                        self.emit("}");
                        return;
                    }
                }
                self.gen_expr(func);
                self.emit("(");
                for (i, arg) in args.iter().enumerate() {
                    if i > 0 { self.emit(", "); }
                    self.gen_expr(&arg.value);
                }
                self.emit(")");
            }
            Expr::FieldAccess { expr, field } => {
                // Enum access: Color.red → Color_red in C
                if let Expr::Ident(name) = expr.as_ref() {
                    if self.enum_names.contains(name) {
                        self.emit(&format!("{}_{}", name, field));
                        return;
                    }
                }
                self.gen_expr(expr);
                self.emit(".");
                self.emit(field);
            }
            Expr::Index { expr, index } => {
                self.gen_expr(expr);
                self.emit("[");
                self.gen_expr(index);
                self.emit("]");
            }
            Expr::StringInterp { parts } => self.gen_string_interp(parts),
            Expr::Dollar(inner) => self.gen_expr(inner),
            Expr::Question(inner) => self.gen_expr(inner),
            Expr::ArrayLit(elems) | Expr::SeqLit(elems) => {
                self.emit("{");
                for (i, e) in elems.iter().enumerate() {
                    if i > 0 { self.emit(", "); }
                    self.gen_expr(e);
                }
                self.emit("}");
            }
            _ => self.emit("/* expr not yet implemented */"),
        }
    }

    // ── echo() → printf() ──

    fn gen_echo(&mut self, args: &[CallArg]) {
        if args.is_empty() {
            self.emit("printf(\"\\n\")");
            return;
        }

        let arg = &args[0].value;
        match arg {
            Expr::StringLit(s) => {
                self.emit(&format!("printf(\"%s\\n\", \"{}\")", Self::escape_c_string(s)));
            }
            Expr::StringInterp { parts } => {
                self.gen_echo_interp(parts);
            }
            _ => {
                let (fmt, needs_cast) = self.printf_format(arg);
                self.emit(&format!("printf(\"{}\\n\", ", fmt));
                if needs_cast { self.emit("(long long)"); }
                self.gen_expr(arg);
                self.emit(")");
            }
        }
    }

    fn gen_echo_interp(&mut self, parts: &[StringPart]) {
        let mut fmt = String::new();
        let mut exprs: Vec<&Expr> = Vec::new();

        for part in parts {
            match part {
                StringPart::Lit(s) => fmt.push_str(&Self::escape_c_string(s)),
                StringPart::Expr(e) => {
                    let (f, _) = self.printf_format(e);
                    fmt.push_str(f);
                    exprs.push(e);
                }
            }
        }
        fmt.push_str("\\n");

        self.emit(&format!("printf(\"{}\"", fmt));
        for e in &exprs {
            let (_, needs_cast) = self.printf_format(e);
            self.emit(", ");
            if needs_cast { self.emit("(long long)"); }
            self.gen_expr(e);
        }
        self.emit(")");
    }

    fn gen_string_interp(&mut self, parts: &[StringPart]) {
        // For non-echo contexts, generate snprintf or inline concatenation
        // For now, emit as a string literal (simplified)
        self.emit("\"");
        for part in parts {
            match part {
                StringPart::Lit(s) => self.emit(&Self::escape_c_string(s)),
                StringPart::Expr(_) => self.emit("<interp>"),
            }
        }
        self.emit("\"");
    }

    // ── Type inference ──

    fn infer_c_type(&self, expr: &Expr) -> String {
        match expr {
            Expr::IntLit(_) => "int64_t",
            Expr::FloatLit(_) => "double",
            Expr::StringLit(_) | Expr::StringInterp { .. } => "const char*",
            Expr::BoolLit(_) => "bool",
            Expr::RuneLit(_) => "int32_t",
            Expr::Binary { op, left, .. } => match op {
                BinOp::Eq | BinOp::NotEq | BinOp::Less | BinOp::LessEq
                | BinOp::Greater | BinOp::GreaterEq | BinOp::And | BinOp::Or => "bool",
                _ => return self.infer_c_type(left),
            },
            Expr::Call { func, .. } => {
                if let Expr::Ident(name) = func.as_ref() {
                    // Struct constructor
                    if self.type_fields.contains_key(name) {
                        return name.to_string();
                    }
                    return self.var_types.get(name).cloned().unwrap_or_else(|| "int64_t".to_string());
                }
                "int64_t"
            }
            Expr::FieldAccess { expr, .. } => {
                // Color.red → type is Color
                if let Expr::Ident(name) = expr.as_ref() {
                    if self.enum_names.contains(name) {
                        return name.clone();
                    }
                }
                "int64_t"
            }
            Expr::Ident(name) => {
                return self.var_types.get(name).cloned().unwrap_or_else(|| "int64_t".to_string());
            }
            _ => "int64_t",
        }.to_string()
    }
}
