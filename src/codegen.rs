use crate::ast::*;
use std::collections::HashMap;

pub struct CodeGen {
    output: String,
    indent: usize,
    fn_declarations: Vec<String>,
    fn_definitions: Vec<String>,
    var_types: HashMap<String, String>,
}

impl CodeGen {
    pub fn new() -> Self {
        CodeGen {
            output: String::new(),
            indent: 0,
            fn_declarations: Vec::new(),
            fn_definitions: Vec::new(),
            var_types: HashMap::new(),
        }
    }

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

    fn type_to_c(&self, t: &TypeExpr) -> String {
        match t {
            TypeExpr::Named(name) => match name.as_str() {
                "int" => "int64_t".to_string(),
                "int8" => "int8_t".to_string(),
                "int16" => "int16_t".to_string(),
                "int32" => "int32_t".to_string(),
                "int64" => "int64_t".to_string(),
                "uint" => "uint64_t".to_string(),
                "uint8" => "uint8_t".to_string(),
                "uint16" => "uint16_t".to_string(),
                "uint32" => "uint32_t".to_string(),
                "uint64" => "uint64_t".to_string(),
                "float" => "double".to_string(),
                "float32" => "float".to_string(),
                "float64" => "double".to_string(),
                "bool" => "bool".to_string(),
                "string" => "const char*".to_string(),
                "byte" => "uint8_t".to_string(),
                "natural" => "uint64_t".to_string(),
                "rune" => "int32_t".to_string(),
                other => other.to_string(),
            },
            TypeExpr::Generic { name, args } => {
                format!("{}_{}", name, args.iter().map(|a| self.type_to_c(a)).collect::<Vec<_>>().join("_"))
            }
            _ => "void".to_string(),
        }
    }

    pub fn generate(&mut self, stmts: &[Stmt]) -> String {
        // Header
        self.emit("#include <stdio.h>\n");
        self.emit("#include <stdint.h>\n");
        self.emit("#include <stdbool.h>\n");
        self.emit("#include <string.h>\n");
        self.emit("#include <stdlib.h>\n");
        self.emit("\n");

        // Collect function declarations first
        for stmt in stmts {
            if let Stmt::FnDecl { name, params, return_type, .. } = stmt {
                let ret = return_type.as_ref()
                    .map(|t| self.type_to_c(t))
                    .unwrap_or_else(|| "void".to_string());
                let params_str = if params.is_empty() {
                    "void".to_string()
                } else {
                    params.iter()
                        .map(|p| format!("{} {}", self.type_to_c(&p.type_ann), p.name))
                        .collect::<Vec<_>>()
                        .join(", ")
                };
                self.fn_declarations.push(format!("{} {}({});", ret, name, params_str));
            }
        }

        // Emit forward declarations
        for decl in &self.fn_declarations.clone() {
            self.emit(decl);
            self.emit("\n");
        }
        if !self.fn_declarations.is_empty() {
            self.emit("\n");
        }

        // Generate functions
        let mut top_level = Vec::new();
        for stmt in stmts {
            match stmt {
                Stmt::FnDecl { .. } => {
                    self.gen_stmt(stmt);
                    self.emit("\n");
                }
                _ => {
                    top_level.push(stmt);
                }
            }
        }

        // Generate main with top-level code
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

        self.output.clone()
    }

    fn gen_stmt(&mut self, stmt: &Stmt) {
        match stmt {
            Stmt::LetDecl { name, type_ann, value } => {
                self.emit_indent();
                let c_type = if let Some(t) = type_ann {
                    self.type_to_c(t)
                } else if let Some(val) = value {
                    self.infer_c_type(val)
                } else {
                    "void*".to_string()
                };
                self.var_types.insert(name.clone(), c_type.clone());
                self.emit(&format!("{} {} = ", c_type, name));
                if let Some(val) = value {
                    self.gen_expr(val);
                } else {
                    self.emit("0");
                }
                self.emit(";\n");
            }
            Stmt::VarDecl { name, type_ann, value } => {
                self.emit_indent();
                let c_type = if let Some(t) = type_ann {
                    self.type_to_c(t)
                } else if let Some(val) = value {
                    self.infer_c_type(val)
                } else {
                    "int64_t".to_string()
                };
                self.var_types.insert(name.clone(), c_type.clone());
                self.emit(&format!("{} {} = ", c_type, name));
                if let Some(val) = value {
                    self.gen_expr(val);
                } else {
                    self.emit("0");
                }
                self.emit(";\n");
            }
            Stmt::ConstDecl { name, value, .. } => {
                self.emit_indent();
                let c_type = self.infer_c_type(value);
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
                let ret = return_type.as_ref()
                    .map(|t| self.type_to_c(t))
                    .unwrap_or_else(|| "void".to_string());
                let has_return = return_type.is_some();

                let params_str = if params.is_empty() {
                    "void".to_string()
                } else {
                    params.iter()
                        .map(|p| format!("{} {}", self.type_to_c(&p.type_ann), p.name))
                        .collect::<Vec<_>>()
                        .join(", ")
                };

                self.emit(&format!("{} {}({}) {{\n", ret, name, params_str));
                self.indent += 1;

                if has_return {
                    self.emit_indent();
                    self.emit(&format!("{} __result;\n", ret));
                }

                for s in body {
                    self.gen_stmt(s);
                }

                if has_return {
                    self.emit_line("return __result;");
                }

                self.indent -= 1;
                self.emit("}\n");
            }
            Stmt::If { branches, else_body } => {
                for (i, (cond, body)) in branches.iter().enumerate() {
                    self.emit_indent();
                    if i == 0 {
                        self.emit("if (");
                    } else {
                        self.emit("else if (");
                    }
                    self.gen_expr(cond);
                    self.emit(") {\n");
                    self.indent += 1;
                    for s in body {
                        self.gen_stmt(s);
                    }
                    self.indent -= 1;
                    self.emit_indent();
                    self.emit("} ");
                }
                if let Some(body) = else_body {
                    self.emit("else {\n");
                    self.indent += 1;
                    for s in body {
                        self.gen_stmt(s);
                    }
                    self.indent -= 1;
                    self.emit_indent();
                    self.emit("}");
                }
                self.emit("\n");
            }
            Stmt::While { condition, body, label } => {
                if let Some(lbl) = label {
                    self.emit_line(&format!("{}:", lbl));
                }
                self.emit_indent();
                self.emit("while (");
                self.gen_expr(condition);
                self.emit(") {\n");
                self.indent += 1;
                for s in body {
                    self.gen_stmt(s);
                }
                self.indent -= 1;
                self.emit_line("}");
            }
            Stmt::For { var, iter, body, label, .. } => {
                if let Some(lbl) = label {
                    self.emit_line(&format!("{}:", lbl));
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
                        self.emit(&format!("/* for {} in <iter> */\n", var));
                        self.emit_indent();
                        self.emit("{\n");
                    }
                }
                self.indent += 1;
                for s in body {
                    self.gen_stmt(s);
                }
                self.indent -= 1;
                self.emit_line("}");
            }
            Stmt::Break(label) => {
                if let Some(lbl) = label {
                    self.emit_line(&format!("goto {}_end;", lbl));
                } else {
                    self.emit_line("break;");
                }
            }
            Stmt::Continue(label) => {
                if let Some(lbl) = label {
                    self.emit_line(&format!("goto {};", lbl));
                } else {
                    self.emit_line("continue;");
                }
            }
            Stmt::Return => {
                self.emit_line("return __result;");
            }
            Stmt::ExprStmt(expr) => {
                self.emit_indent();
                self.gen_expr(expr);
                self.emit(";\n");
            }
            Stmt::Discard => {
                self.emit_line("/* discard */");
            }
            _ => {
                self.emit_line("/* not implemented */");
            }
        }
    }

    fn gen_expr(&mut self, expr: &Expr) {
        match expr {
            Expr::IntLit(n) => self.emit(&format!("{}", n)),
            Expr::FloatLit(n) => self.emit(&format!("{}", n)),
            Expr::StringLit(s) => self.emit(&format!("\"{}\"", s.replace('"', "\\\""))),
            Expr::RuneLit(c) => self.emit(&format!("'{}'", c)),
            Expr::BoolLit(b) => self.emit(if *b { "true" } else { "false" }),
            Expr::Ident(name) => self.emit(name),
            Expr::Binary { left, op, right } => {
                self.emit("(");
                self.gen_expr(left);
                let op_str = match op {
                    BinOp::Add => " + ",
                    BinOp::Sub => " - ",
                    BinOp::Mul => " * ",
                    BinOp::Div => " / ",
                    BinOp::Mod => " % ",
                    BinOp::Eq => " == ",
                    BinOp::NotEq => " != ",
                    BinOp::Less => " < ",
                    BinOp::LessEq => " <= ",
                    BinOp::Greater => " > ",
                    BinOp::GreaterEq => " >= ",
                    BinOp::And => " && ",
                    BinOp::Or => " || ",
                    BinOp::Pipe => " | ",
                };
                self.emit(op_str);
                self.gen_expr(right);
                self.emit(")");
            }
            Expr::Unary { op, expr } => {
                match op {
                    UnaryOp::Neg => self.emit("-"),
                    UnaryOp::Not => self.emit("!"),
                }
                self.gen_expr(expr);
            }
            Expr::Call { func, args } => {
                // Special case: echo -> printf
                if let Expr::Ident(name) = func.as_ref() {
                    if name == "echo" {
                        self.gen_echo(args);
                        return;
                    }
                }
                self.gen_expr(func);
                self.emit("(");
                for (i, arg) in args.iter().enumerate() {
                    if i > 0 {
                        self.emit(", ");
                    }
                    self.gen_expr(&arg.value);
                }
                self.emit(")");
            }
            Expr::FieldAccess { expr, field } => {
                self.gen_expr(expr);
                self.emit(&format!(".{}", field));
            }
            Expr::Index { expr, index } => {
                self.gen_expr(expr);
                self.emit("[");
                self.gen_expr(index);
                self.emit("]");
            }
            Expr::Dollar(inner) => {
                // $ operator — string conversion, for now just pass through
                self.gen_expr(inner);
            }
            Expr::Question(inner) => {
                // ? operator — error propagation, simplified
                self.gen_expr(inner);
            }
            Expr::ArrayLit(elems) => {
                self.emit("{");
                for (i, e) in elems.iter().enumerate() {
                    if i > 0 {
                        self.emit(", ");
                    }
                    self.gen_expr(e);
                }
                self.emit("}");
            }
            Expr::StringInterp { parts } => {
                self.gen_string_interp(parts);
            }
            Expr::SeqLit(elems) => {
                self.emit("/* seq */ {");
                for (i, e) in elems.iter().enumerate() {
                    if i > 0 {
                        self.emit(", ");
                    }
                    self.gen_expr(e);
                }
                self.emit("}");
            }
            _ => self.emit("/* expr not implemented */"),
        }
    }

    fn gen_echo(&mut self, args: &[CallArg]) {
        if args.is_empty() {
            self.emit("printf(\"\\n\")");
            return;
        }

        let arg = &args[0].value;
        match arg {
            Expr::StringLit(s) => {
                self.emit(&format!("printf(\"%s\\n\", \"{}\")", s.replace('\n', "\\n").replace('"', "\\\"")));
            }
            Expr::StringInterp { parts } => {
                let mut fmt = String::new();
                let mut format_args = Vec::new();
                for part in parts {
                    match part {
                        StringPart::Lit(s) => {
                            fmt.push_str(&s.replace('\n', "\\n").replace('"', "\\\""));
                        }
                        StringPart::Expr(e) => {
                            // Use %s for string-like, %lld for numeric
                            fmt.push_str("%s");
                            format_args.push(e);
                        }
                    }
                }
                fmt.push_str("\\n");
                self.emit(&format!("printf(\"{}\"", fmt));
                for e in &format_args {
                    self.emit(", ");
                    self.gen_expr(e);
                }
                self.emit(")");
            }
            Expr::IntLit(n) => {
                self.emit(&format!("printf(\"%lld\\n\", (long long){})", n));
            }
            Expr::Ident(name) => {
                let is_string = self.var_types.get(name)
                    .map(|t| t == "const char*")
                    .unwrap_or(false);
                if is_string {
                    self.emit(&format!("printf(\"%s\\n\", {})", name));
                } else {
                    self.emit(&format!("printf(\"%lld\\n\", (long long){})", name));
                }
            }
            _ => {
                self.emit("printf(\"%lld\\n\", (long long)");
                self.gen_expr(arg);
                self.emit(")");
            }
        }
    }

    fn gen_string_interp(&mut self, parts: &[StringPart]) {
        // Generate as printf-style
        let mut fmt = String::new();
        let mut exprs: Vec<&Expr> = Vec::new();
        for part in parts {
            match part {
                StringPart::Lit(s) => {
                    fmt.push_str(&s.replace('"', "\\\""));
                }
                StringPart::Expr(e) => {
                    fmt.push_str("%lld");
                    exprs.push(e);
                }
            }
        }
        self.emit("/* interp */ \"");
        self.emit(&fmt);
        self.emit("\"");
    }

    fn infer_c_type(&self, expr: &Expr) -> String {
        match expr {
            Expr::IntLit(_) => "int64_t".to_string(),
            Expr::FloatLit(_) => "double".to_string(),
            Expr::StringLit(_) => "const char*".to_string(),
            Expr::BoolLit(_) => "bool".to_string(),
            Expr::RuneLit(_) => "int32_t".to_string(),
            Expr::Binary { left, op, .. } => {
                match op {
                    BinOp::Eq | BinOp::NotEq | BinOp::Less | BinOp::LessEq
                    | BinOp::Greater | BinOp::GreaterEq | BinOp::And | BinOp::Or => {
                        "bool".to_string()
                    }
                    _ => self.infer_c_type(left),
                }
            }
            Expr::Call { .. } => "int64_t".to_string(), // default
            _ => "int64_t".to_string(),
        }
    }
}
