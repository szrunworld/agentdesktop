// Generates a macOS Seatbelt (sandbox-exec) profile for an outbound executor.
// sandbox-exec(1) is marked deprecated by Apple but still ships and is what Codex,
// Gemini CLI and Chromium use on macOS. Rules: last matching rule wins.
export function sandboxProfile(o: { readAllow: string[]; writeAllow: string[]; execAllow: string[]; netAllow: string[] }) {
  const q = (s: string) => JSON.stringify(s);
  return `(version 1)
(allow default)

; --- files: no reads under user/tmp areas except the allowlist ---------------
(deny file-read-data (subpath "/Users") (subpath "/private/tmp") (subpath "/private/var/folders") (subpath "/Volumes"))
(allow file-read-data ${o.readAllow.map((p) => `(subpath ${q(p)})`).join(" ")})

; --- writes only inside the run's home and work dir ---------------------------
(deny file-write*)
(allow file-write* ${o.writeAllow.map((p) => `(subpath ${q(p)})`).join(" ")}
  (literal "/dev/null") (literal "/dev/zero") (regex #"^/dev/tty") (regex #"^/dev/fd/"))

; --- exec only the agent runtime itself (no shells, curl, downloaded binaries)
(deny process-exec)
(allow process-exec ${o.execAllow.map((p) => `(literal ${q(p)})`).join(" ")})

; --- network: only the model endpoint ------------------------------------------
(deny network-outbound)
(allow network-outbound ${o.netAllow.map((p) => `(remote ip ${q(p)})`).join(" ")})
`;
}
