# Region observation extension v1 (#105)

Probe `runtime.capabilities.regionObservation.version == 1` and the method list for `observe.region`. This additive method leaves frozen `observe` params and existing image fields intact.

Use the same context and grants as observe, with optional `region` (global point rectangle) and/or `maxWidth` (1–4096 output pixels). At least one is required. `elements` and `query` retain their existing meaning; use elements=false for image-only reads. Screenshot generation is always enabled.

The requested region must lie wholly inside the authorized bound-window image (or the owner's authorized screen image). Partial intersection is refused. Cropping rounds inward to full pixels. maxWidth only reduces size, preserving a uniform coordinate scale; a fractional bottom row may be transparent. ImageTransform reports the cropped origin and resized scale, and the stored snapshot uses the same mapping for later imagePoint actions.

The existing target exposure, process/window/generation validation, quota accounting, artifact principal ownership, persist grant, transient expiry and revocation rules apply. The full authorized image is transformed locally before registration; only the smaller artifact is returned. This is not a direct sensor region capture: full authorized pixels temporarily exist within Runtime memory and its protected temporary image file. Bound-window capture still never captures a whole display first.

On unsupported hosts, keep the current observe plus local crop workflow. Examples:

```json
{"method":"observe.region","context":{"sessionId":"ses_example"},"params":{"region":{"x":2100,"y":150,"width":360,"height":360},"maxWidth":360,"elements":false}}
```

Envelope apiVersion and requestId are required as usual. Out-of-bounds or empty regions return invalid_argument, and the temporary image is removed. Cropping does not grant access to any new window or bypass target validation.
