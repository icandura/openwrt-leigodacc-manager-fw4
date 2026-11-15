import difflib

src = open("leigod-fw4.sh", encoding="utf-8").read().split("\n")
start = None
for i, line in enumerate(src):
    if 'cat > "$luci_src/controller/acc.lua" <<' in line:
        start = i + 1
        break
assert start, "controller heredoc not found"
end = next(j for j in range(start, len(src)) if src[j] == "LUAEOF")
inline = src[start:end]
stand = open("luci-fw4-patch/luasrc/controller/acc.lua", encoding="utf-8").read().rstrip("\n").split("\n")
diff = list(difflib.unified_diff(stand, inline, "standalone", "inline", lineterm="", n=0))
print("inline=%d standalone=%d diff=%d" % (len(inline), len(stand), len(diff)))
for line in diff[:24]:
    print(line)
