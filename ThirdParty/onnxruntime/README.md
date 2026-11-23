# ONNX Runtime 1.24.2 for Apple platforms

What `AgentKokoro` runs its models on, kept in this package since
2026-11-22, when Microsoft's `onnxruntime-swift-package-manager`
repository on GitHub returned 404 and `download.onnxruntime.ai`, the host
its binary came from, stopped serving it (its certificate no longer names
it). Both are MIT (`LICENSE`, Microsoft's).

- `objectivec/`: the Objective-C bindings from
  `onnxruntime-swift-package-manager` tag `1.24.2` (commit `b7fb7f7`,
  "Update ORT to 1.24.2"), unmodified. Left out, as Microsoft's
  `Package.swift` excluded them: the training API (`ort_checkpoint*`,
  `ort_training_session*`, `onnxruntime_training.h`), tests, docs and the
  format script. Built as the `OnnxRuntimeBindings` target with `SPM_BUILD`
  defined and C++17, as theirs was.
- The binary, `onnxruntime.xcframework` (pod archive `onnxruntime-c`
  1.24.2, full build, static), is the same archive byte for byte, hosted by
  us:

  ```
  https://storage.googleapis.com/flisk447-media/vendor/onnxruntime/pod-archive-onnxruntime-c-1.24.2.zip
  sha256 f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54
  ```

  The checksum is Microsoft's own, from their `Package.swift`; SwiftPM
  checks it on every download. The object is public-read (MIT); nothing
  else under `vendor/` in that bucket.
- Not kept: `onnxruntime_extensions` (the package's other product), which
  nothing here used.

To move to a new version: build or obtain the pod archive
(`tools/ci_build/github/apple/build_and_assemble_apple_pods.py` in
microsoft/onnxruntime), check its licence inventory (the package README,
"On-device neural voice"), copy it beside this one with
`gcloud storage cp FILE gs://flisk447-media/vendor/onnxruntime/ --predefined-acl=publicRead`,
replace `objectivec/` with the matching bindings, and update the URL and
`swift package compute-checksum FILE` in `Package.swift`.
