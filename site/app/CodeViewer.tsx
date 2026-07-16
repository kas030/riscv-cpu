type TokenKind =
  | "comment"
  | "directive"
  | "keyword"
  | "number"
  | "operator"
  | "string"
  | "system";

type SyntaxToken = {
  text: string;
  kind?: TokenKind;
};

const systemVerilogKeywords = new Set([
  "always",
  "always_comb",
  "always_ff",
  "always_latch",
  "and",
  "assign",
  "automatic",
  "begin",
  "bit",
  "break",
  "case",
  "casex",
  "casez",
  "class",
  "const",
  "continue",
  "default",
  "do",
  "else",
  "end",
  "endcase",
  "endclass",
  "endfunction",
  "endgenerate",
  "endmodule",
  "endpackage",
  "endtask",
  "enum",
  "for",
  "foreach",
  "forever",
  "fork",
  "function",
  "generate",
  "genvar",
  "if",
  "initial",
  "inout",
  "input",
  "integer",
  "interface",
  "localparam",
  "logic",
  "module",
  "or",
  "output",
  "package",
  "parameter",
  "reg",
  "repeat",
  "return",
  "signed",
  "struct",
  "task",
  "typedef",
  "union",
  "unique",
  "unsigned",
  "virtual",
  "void",
  "wait",
  "while",
  "wire",
]);

const sizedNumberPattern = /^(?:\d[\d_]*)?'[sS]?[bBoOdDhH][0-9a-fA-F_xXzZ?]+/;
const unsizedNumberPattern = /^'(?:0|1|x|X|z|Z)/;
const decimalNumberPattern = /^\d[\d_]*/;
const identifierPattern = /^[A-Za-z_][A-Za-z0-9_$]*/;
const directivePattern = /^`[A-Za-z_][A-Za-z0-9_$]*/;
const systemTaskPattern = /^\$[A-Za-z_][A-Za-z0-9_$]*/;
const operatorPattern = /^(?:===|!==|<<<|>>>|<<=|>>=|==|!=|<=|>=|&&|\|\||<<|>>|\+\+|--|\*\*|->|=>|[+\-*/%&|^~!=<>?:])/;

function tokenizeSystemVerilog(code: string) {
  let inBlockComment = false;

  return code.replace(/\r\n?/g, "\n").split("\n").map((line) => {
    const tokens: SyntaxToken[] = [];
    let cursor = 0;

    const push = (text: string, kind?: TokenKind) => {
      if (text) tokens.push({ text, kind });
    };

    while (cursor < line.length) {
      if (inBlockComment) {
        const end = line.indexOf("*/", cursor);
        if (end === -1) {
          push(line.slice(cursor), "comment");
          cursor = line.length;
          continue;
        }
        push(line.slice(cursor, end + 2), "comment");
        cursor = end + 2;
        inBlockComment = false;
        continue;
      }

      if (line.startsWith("//", cursor)) {
        push(line.slice(cursor), "comment");
        break;
      }

      if (line.startsWith("/*", cursor)) {
        const end = line.indexOf("*/", cursor + 2);
        if (end === -1) {
          push(line.slice(cursor), "comment");
          inBlockComment = true;
          break;
        }
        push(line.slice(cursor, end + 2), "comment");
        cursor = end + 2;
        continue;
      }

      if (line[cursor] === '"') {
        let end = cursor + 1;
        while (end < line.length) {
          if (line[end] === "\\") {
            end += 2;
            continue;
          }
          end += 1;
          if (line[end - 1] === '"') break;
        }
        push(line.slice(cursor, end), "string");
        cursor = end;
        continue;
      }

      const rest = line.slice(cursor);
      const directive = rest.match(directivePattern)?.[0];
      if (directive) {
        push(directive, "directive");
        cursor += directive.length;
        continue;
      }

      const systemTask = rest.match(systemTaskPattern)?.[0];
      if (systemTask) {
        push(systemTask, "system");
        cursor += systemTask.length;
        continue;
      }

      const number = rest.match(sizedNumberPattern)?.[0]
        ?? rest.match(unsizedNumberPattern)?.[0]
        ?? rest.match(decimalNumberPattern)?.[0];
      if (number) {
        push(number, "number");
        cursor += number.length;
        continue;
      }

      const identifier = rest.match(identifierPattern)?.[0];
      if (identifier) {
        push(identifier, systemVerilogKeywords.has(identifier) ? "keyword" : undefined);
        cursor += identifier.length;
        continue;
      }

      const operator = rest.match(operatorPattern)?.[0];
      if (operator) {
        push(operator, "operator");
        cursor += operator.length;
        continue;
      }

      const plain = rest.match(/^[^A-Za-z0-9_`$'"/+\-*%&|^~!=<>?:]+/)?.[0] ?? rest[0];
      push(plain);
      cursor += plain.length;
    }

    return tokens;
  });
}

export function CodeViewer({ code, startLine = 1 }: { code: string; startLine?: number }) {
  const lines = tokenizeSystemVerilog(code);
  const endLine = startLine + lines.length - 1;

  return (
    <div className="code-viewer" role="region" aria-label={`SystemVerilog 源码，第 ${startLine} 至 ${endLine} 行`}>
      <pre tabIndex={0} aria-label="可横向滚动的 SystemVerilog 源码">
        <code>
          {lines.map((tokens, index) => (
            <span className="code-line" key={`${startLine + index}-${tokens.map((token) => token.text).join("")}`}>
              <span className="line-number" aria-hidden="true">{startLine + index}</span>
              <span className="line-content">
                {tokens.map((token, tokenIndex) => token.kind
                  ? <span className={`sv-${token.kind}`} key={`${tokenIndex}-${token.text}`}>{token.text}</span>
                  : token.text)}
              </span>
            </span>
          ))}
        </code>
      </pre>
    </div>
  );
}
