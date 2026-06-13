#!/usr/bin/env python3
"""Reconstruct iTerm2's api.proto from the installed `iterm2` package descriptor.

Fully offline and version-exact: emits the proto2 schema that the running
`iterm2` Python lib (and therefore the live iTerm2 build) actually speaks, so
the native Swift client is generated against the identical wire format.
"""
import sys
from google.protobuf import descriptor_pb2
from iterm2 import api_pb2

FD = descriptor_pb2.FieldDescriptorProto

SCALAR = {
    FD.TYPE_DOUBLE: "double", FD.TYPE_FLOAT: "float", FD.TYPE_INT64: "int64",
    FD.TYPE_UINT64: "uint64", FD.TYPE_INT32: "int32", FD.TYPE_FIXED64: "fixed64",
    FD.TYPE_FIXED32: "fixed32", FD.TYPE_BOOL: "bool", FD.TYPE_STRING: "string",
    FD.TYPE_BYTES: "bytes", FD.TYPE_UINT32: "uint32", FD.TYPE_SFIXED32: "sfixed32",
    FD.TYPE_SFIXED64: "sfixed64", FD.TYPE_SINT32: "sint32", FD.TYPE_SINT64: "sint64",
}
LABEL = {FD.LABEL_OPTIONAL: "optional", FD.LABEL_REQUIRED: "required", FD.LABEL_REPEATED: "repeated"}


def field_type(f):
    if f.type in (FD.TYPE_MESSAGE, FD.TYPE_ENUM, FD.TYPE_GROUP):
        return f.type_name  # fully-qualified, leading-dot form is valid proto2
    return SCALAR[f.type]


def fmt_default(f):
    if not f.HasField("default_value"):
        return ""
    v = f.default_value
    if f.type == FD.TYPE_STRING:
        v = '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
    elif f.type == FD.TYPE_BYTES:
        v = '"' + v + '"'
    return f" [default = {v}]"


def emit_field(f, ind):
    # Skip fields that belong to a oneof; those are emitted inside the oneof block.
    label = LABEL[f.label] + " " if f.label != FD.LABEL_REPEATED or True else ""
    return f"{ind}{LABEL[f.label]} {field_type(f)} {f.name} = {f.number}{fmt_default(f)};"


def emit_enum(e, ind):
    out = [f"{ind}enum {e.name} {{"]
    for v in e.value:
        out.append(f"{ind}  {v.name} = {v.number};")
    out.append(f"{ind}}}")
    return out


def emit_message(m, ind):
    out = [f"{ind}message {m.name} {{"]
    inner = ind + "  "
    for ne in m.enum_type:
        out += emit_enum(ne, inner)
    for nm in m.nested_type:
        if nm.options.map_entry:  # synthetic map entry: skip, handled by map<> sugar (none here)
            continue
        out += emit_message(nm, inner)
    # group fields by oneof
    oneof_fields = {}
    for f in m.field:
        if f.HasField("oneof_index"):
            oneof_fields.setdefault(f.oneof_index, []).append(f)
    emitted_oneofs = set()
    for f in m.field:
        if f.HasField("oneof_index"):
            idx = f.oneof_index
            if idx in emitted_oneofs:
                continue
            emitted_oneofs.add(idx)
            out.append(f"{inner}oneof {m.oneof_decl[idx].name} {{")
            for of in oneof_fields[idx]:
                out.append(f"{inner}  {field_type(of)} {of.name} = {of.number}{fmt_default(of)};")
            out.append(f"{inner}}}")
        else:
            out.append(emit_field(f, inner))
    out.append(f"{ind}}}")
    return out


def main():
    fdp = descriptor_pb2.FileDescriptorProto()
    api_pb2.DESCRIPTOR.CopyToProto(fdp)
    out = ['syntax = "proto2";', "", f"package {fdp.package};", ""]
    if fdp.options.objc_class_prefix:
        out.append(f'option objc_class_prefix = "{fdp.options.objc_class_prefix}";')
        out.append("")
    for e in fdp.enum_type:
        out += emit_enum(e, "")
        out.append("")
    for m in fdp.message_type:
        out += emit_message(m, "")
        out.append("")
    sys.stdout.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
