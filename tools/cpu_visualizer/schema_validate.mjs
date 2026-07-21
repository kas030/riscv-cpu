// Small dependency-free JSON Schema subset used by the visualizer contracts.
// It intentionally implements every keyword used by the checked-in schemas.
export function validateAgainstSchema(value, schema, options = {}) {
  const root = options.root ?? schema;
  const errors = [];
  const visit = (current, rule, path) => {
    if (rule.$ref) {
      if (!rule.$ref.startsWith("#/$defs/")) return errors.push(`${path}: unsupported $ref ${rule.$ref}`);
      const target = root.$defs?.[rule.$ref.slice("#/$defs/".length)];
      if (!target) return errors.push(`${path}: unresolved $ref ${rule.$ref}`);
      return visit(current, target, path);
    }
    if (rule.const !== undefined && current !== rule.const) errors.push(`${path}: expected constant ${JSON.stringify(rule.const)}`);
    if (rule.enum && !rule.enum.some((item) => item === current)) errors.push(`${path}: value is not in enum`);
    if (rule.oneOf) {
      const matches = rule.oneOf.filter((candidate) => validateAgainstSchema(current, candidate, { root }).length === 0);
      if (matches.length !== 1) errors.push(`${path}: expected exactly one oneOf match, got ${matches.length}`);
      return;
    }
    const typeMatches = (type) => type === "null" ? current === null
      : type === "array" ? Array.isArray(current)
        : type === "object" ? current !== null && typeof current === "object" && !Array.isArray(current)
          : type === "integer" ? Number.isInteger(current)
            : typeof current === type;
    if (rule.type) {
      const allowed = Array.isArray(rule.type) ? rule.type : [rule.type];
      if (!allowed.some(typeMatches)) { errors.push(`${path}: expected ${allowed.join("|")}`); return; }
    }
    if (typeof current === "string") {
      if (rule.minLength !== undefined && current.length < rule.minLength) errors.push(`${path}: shorter than ${rule.minLength}`);
      if (rule.pattern && !new RegExp(rule.pattern).test(current)) errors.push(`${path}: does not match ${rule.pattern}`);
    }
    if (typeof current === "number" && rule.minimum !== undefined && current < rule.minimum) errors.push(`${path}: smaller than ${rule.minimum}`);
    if (Array.isArray(current)) {
      if (rule.minItems !== undefined && current.length < rule.minItems) errors.push(`${path}: fewer than ${rule.minItems} items`);
      if (rule.maxItems !== undefined && current.length > rule.maxItems) errors.push(`${path}: more than ${rule.maxItems} items`);
      if (rule.items) current.forEach((item, index) => visit(item, rule.items, `${path}[${index}]`));
    } else if (current !== null && typeof current === "object") {
      for (const key of rule.required ?? []) if (!(key in current)) errors.push(`${path}: missing ${key}`);
      for (const [key, item] of Object.entries(current)) {
        if (rule.properties?.[key]) visit(item, rule.properties[key], `${path}.${key}`);
        else if (rule.additionalProperties === false) errors.push(`${path}: unexpected property ${key}`);
        else if (rule.additionalProperties && typeof rule.additionalProperties === "object") visit(item, rule.additionalProperties, `${path}.${key}`);
      }
    }
  };
  visit(value, schema, options.path ?? "$");
  return errors;
}
