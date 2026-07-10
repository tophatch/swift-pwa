#if os(Android) && CRITTERFACTS_LAMA_SMOKE
    // Tiny embedded test image + mask for the on-device LaMa smoke (see
    // CritterFacts.swift). 96×72 gray with a red block, and a white-on-black
    // mask over that block — small enough to inline as base64 PNGs, so the
    // smoke needs no bundled files or filesystem access on Android.
    let cfSmokeImageBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAGAAAABICAIAAACGBWc0AAAAw0lEQVR4nO3ZIQ7DMBQFQafqUYOLfY7gHLYnSJZEVsAMtWSweuxvc87Btc/NGwI1CwoCBYGCQEGgIFAQKAgUBAoCBYGCQEGgIFAQKAgUBAoCBYGCQEGgIFAQKHzHQr/zfOSfY9/HKhYUBAoCBYGCQEGgIFAQKAgUBAoCBYGCQEGgIFAQKAgUBAoCBYGCQEGgINCb7mLHwnvWUywoCBQECgIFgYJAQaAgUBAoCBQECgIFgYJAQaAgUBAoCBQECgIFgca9Pz/5BlZiwhBUAAAAAElFTkSuQmCC"
    let cfSmokeMaskBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAGAAAABICAIAAACGBWc0AAAAZ0lEQVR4nO3QwQ2AMAwEQYf+ew4dsB8UCTRTgH3aGQAAAAAAAACerTlo7/3KnbXOzb6OffoogYJAQaAgUBAoCBQECgIFgYJAQaAgUBAoCBQECgIFgYJAQaAgUBAoCAQAAAAAADB/cAPzaQMww7+VoQAAAABJRU5ErkJggg=="
#endif
