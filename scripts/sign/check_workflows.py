#!/usr/bin/env python3
"""Check GitHub Actions workflows against the signing rules.

    python3 -I scripts/sign/check_workflows.py WORKFLOW...

Every workflow must:
  - parse with PyYAML's safe loader into a mapping with 'on' and 'jobs', with
    no key given twice in one mapping (GitHub refuses those files);
  - keep secrets out of every job and step `if:`: GitHub does not allow the
    secrets context there, so gate on a job-level env boolean instead;
  - keep the secrets context out of every `${{ }}` in a `run:` script: map
    the secret into the step's env, so the shell reads a variable and the
    value is never pasted into the script.

A workflow whose file name is in SELF_TESTS must also:
  - run only on workflow_dispatch;
  - reference no secret at all (no secrets.NAME, secrets['NAME'], whole
    `secrets` as in toJSON(secrets), or a job's `secrets:` key,
    `secrets: inherit` included);
  - carry the repository guard on every job, in an `if:` with no `||` that
    could bypass it;
  - declare top-level permissions, and give no write scope at either level.

Prints one PASS line per workflow on stdout and one FAIL line per broken rule
on stderr. Exit 0 when every workflow passes, 1 when one breaks a rule, 2 on a
usage error or a file that cannot be read or parsed (or no PyYAML).

A secret reference is the word `secrets` anywhere in an expression, in any
letter case (GitHub's context names ignore case), whatever follows it, unless
it is a property name (`steps.secrets`) or sits inside a 'string literal'.
Expressions are read as GitHub reads them: a `}}` inside a literal does not
end one.
"""

import os
import re
import sys

REPO = "voidlore/ontomeme"
GUARD = re.compile(r"\bgithub\.repository\s*==\s*'" + re.escape(REPO) + r"'")

# Workflows that run by hand with throwaway certificates: they never see a
# repository secret, so a run on any fork proves nothing it should not.
SELF_TESTS = {"signing-selftest.yml"}

# The secrets context itself: secrets.NAME, secrets['NAME'], and the whole
# object (toJSON(secrets), a bare secrets) alike. Not a property or a longer
# name: steps.secrets, my-secrets, secrets_dir.
SECRETS_REF = re.compile(r"(?<![\w.-])secrets(?![\w-])", re.I)
# A string literal in an expression; '' inside one is an escaped quote.
LITERAL = re.compile(r"'(?:[^']|'')*'")


class UsageError(Exception):
    pass


def load_yaml(path):
    """The workflow as plain Python data; a duplicated mapping key is an error."""
    try:
        import yaml
    except ImportError as exc:
        raise UsageError("check_workflows.py needs PyYAML (apt install python3-yaml)") from exc

    class UniqueKeyLoader(yaml.SafeLoader):
        pass

    def unique_mapping(loader, node, deep=False):
        seen = set()
        for key_node, _value in node.value:
            key = loader.construct_object(key_node, deep=deep)
            if key in seen:
                raise yaml.constructor.ConstructorError(
                    None, None, f"duplicate key {key!r}", key_node.start_mark)
            seen.add(key)
        return loader.construct_mapping(node, deep)

    UniqueKeyLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, unique_mapping)
    try:
        with open(path, encoding="utf-8") as f:
            return yaml.load(f, Loader=UniqueKeyLoader)
    except OSError as exc:
        raise UsageError(f"{path}: {exc.strerror or exc}") from exc
    except yaml.YAMLError as exc:
        raise UsageError(f"{path}: not valid YAML: {exc}".replace("\n", " ")) from exc


def triggers(workflow):
    """The event names under `on:` (PyYAML reads the bare key `on` as True)."""
    on = workflow.get("on", workflow.get(True))
    if isinstance(on, str):
        return {on}
    if isinstance(on, (list, dict)):
        return {str(event) for event in on}
    return set()


def jobs(workflow):
    value = workflow.get("jobs")
    return value if isinstance(value, dict) else {}


def steps(job):
    value = job.get("steps") if isinstance(job, dict) else None
    return [step for step in value if isinstance(step, dict)] if isinstance(value, list) else []


def step_label(job_id, index, step):
    name = step.get("name") or step.get("id") or step.get("uses") or f"step {index + 1}"
    return f"job '{job_id}', step '{name}'"


def strings(value, path=""):
    """Every (where, text) string in the data, mapping keys included."""
    if isinstance(value, str):
        yield path, value
    elif isinstance(value, dict):
        for key, item in value.items():
            where = f"{path}.{key}" if path else str(key)
            if isinstance(key, str):
                yield where, key
            yield from strings(item, where)
    elif isinstance(value, list):
        for index, item in enumerate(value):
            yield from strings(item, f"{path}[{index}]")


def expressions(text):
    """The body of every `${{ }}` in text, scanned as GitHub's runner scans it:
    a quote opens or closes a string literal, and only a `}}` outside one ends
    the expression. An unclosed expression runs to the end of the text."""
    found, start = [], text.find("${{")
    while start != -1:
        end, quoted = start + 3, False
        while end < len(text) - 1:
            if text[end] == "'":
                quoted = not quoted
            elif not quoted and text.startswith("}}", end):
                break
            end += 1
        else:
            end = len(text)
        found.append(text[start + 3:end])
        start = text.find("${{", end + 2)
    return found


def references_secrets(expression):
    """Whether the expression reads the secrets context (literals aside)."""
    return bool(SECRETS_REF.search(LITERAL.sub("''", expression)))


def condition_references_secrets(condition):
    """An `if:` is an expression even without `${{ }}`; with them, only the
    text inside them is evaluated."""
    if "${{" in condition:
        return any(references_secrets(e) for e in expressions(condition))
    return references_secrets(condition)


def conditions(workflow):
    """(label, if-text) for every job and step `if:`."""
    for job_id, job in jobs(workflow).items():
        if isinstance(job, dict) and "if" in job:
            yield f"job '{job_id}'", str(job["if"])
        for index, step in enumerate(steps(job)):
            if "if" in step:
                yield step_label(job_id, index, step), str(step["if"])


def check_common(workflow):
    findings = []
    if not triggers(workflow):
        findings.append("has no 'on:' triggers")
    if not jobs(workflow):
        findings.append("has no jobs")
    for label, condition in conditions(workflow):
        if condition_references_secrets(condition):
            findings.append(f"{label}: secrets in an if: (GitHub refuses it; gate on a job env boolean)")
    for job_id, job in jobs(workflow).items():
        for index, step in enumerate(steps(job)):
            run = step.get("run")
            if isinstance(run, str) and any(references_secrets(e) for e in expressions(run)):
                findings.append(f"{step_label(job_id, index, step)}: a secret is pasted into run:; "
                                "map it into the step's env instead")
    return findings


def write_scopes(permissions):
    if isinstance(permissions, str):
        return [permissions] if permissions == "write-all" else []
    if isinstance(permissions, dict):
        return [f"{scope}: {level}" for scope, level in permissions.items() if level == "write"]
    return []


def check_self_test(workflow):
    findings = []
    events = triggers(workflow)
    if events and events != {"workflow_dispatch"}:
        others = ", ".join(sorted(events - {"workflow_dispatch"}))
        findings.append(f"runs on {others}; a self-test runs on workflow_dispatch only")
    for where, text in strings(workflow):
        if any(references_secrets(e) for e in expressions(text)):
            findings.append(f"{where}: references a secret; a self-test uses none")
    for label, condition in conditions(workflow):
        if "${{" not in condition and references_secrets(condition):
            findings.append(f"{label}: references a secret; a self-test uses none")
    if "permissions" not in workflow:
        findings.append("declares no top-level permissions (want contents: read)")
    for scope in write_scopes(workflow.get("permissions")):
        findings.append(f"permissions give '{scope}'; a self-test needs no write scope")
    for job_id, job in jobs(workflow).items():
        if not isinstance(job, dict):
            findings.append(f"job '{job_id}' is not a mapping")
            continue
        if "secrets" in job:
            findings.append(f"job '{job_id}' passes secrets: to a reusable workflow; a self-test uses none")
        condition = str(job.get("if", ""))
        if not GUARD.search(condition):
            findings.append(f"job '{job_id}' lacks the guard if: github.repository == '{REPO}'")
        elif "||" in condition:
            findings.append(f"job '{job_id}': '||' in its if: can bypass the repository guard")
        for scope in write_scopes(job.get("permissions")):
            findings.append(f"job '{job_id}' permissions give '{scope}'; a self-test needs no write scope")
    return findings


def check_workflow(path):
    """The findings for one workflow file; raises UsageError when unreadable."""
    workflow = load_yaml(path)
    if not isinstance(workflow, dict):
        raise UsageError(f"{path}: not a workflow (the top level is not a mapping)")
    findings = check_common(workflow)
    if os.path.basename(path) in SELF_TESTS:
        findings += check_self_test(workflow)
    return list(dict.fromkeys(findings))


def main(argv=None):
    paths = sys.argv[1:] if argv is None else argv
    if not paths or any(p.startswith("-") for p in paths):
        print("usage: check_workflows.py WORKFLOW...", file=sys.stderr)
        return 2
    failed, errors = False, False
    for path in paths:
        try:
            findings = check_workflow(path)
        except UsageError as exc:
            print(f"ERROR {exc}", file=sys.stderr)
            errors = True
            continue
        for finding in findings:
            print(f"FAIL {path}: {finding}", file=sys.stderr)
        if findings:
            failed = True
        else:
            kind = "self-test rules" if os.path.basename(path) in SELF_TESTS else "common rules"
            print(f"PASS {path} ({kind})")
    if errors:
        return 2
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
