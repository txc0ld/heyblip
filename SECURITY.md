# Security Policy

## Reporting Vulnerabilities

If you discover a security vulnerability in Blip, please report it responsibly.

**Do NOT open a public GitHub issue for security vulnerabilities.**

Contact: Open a private security advisory on this repository.

## Security Architecture

Blip implements defense-in-depth encryption for all communications:

### End-to-End Encryption
- **Protocol**: Noise_XX_25519_ChaChaPoly_SHA256
- **Key Exchange**: Curve25519 Diffie-Hellman
- **Symmetric Cipher**: ChaChaPoly (AEAD)
- **Hash**: SHA-256
- **Forward Secrecy**: Yes (ephemeral keys per session)
- **Replay Protection**: Sliding window nonce (64-bit counter + 128-bit bitmap)

### Group Encryption
- **Scheme**: Sender Key with AES-256-GCM
- **Key Rotation**: On member removal, block, or every 100 messages

### Identity
- **Signing**: Ed25519
- **Key Storage**: iOS Keychain (`kSecAttrAccessibleAfterFirstUnlock`)
- **Phone Privacy**: SHA256(phone + per-user random salt) — raw number never transmitted

### Mesh Security
- **Packet Signing**: Ed25519 signatures on all broadcast packets
- **Traffic Analysis Resistance**: PKCS#7 padding to fixed block sizes (256/512/1024/2048)
- **Organizer Authentication**: Ed25519 key in signed event manifest
- **Reputation System**: Decentralized block-vote mechanism for abuse prevention

### What We Don't Do
- No server-side key storage
- No server-side message storage
- No persistent identifiers in BLE advertisements
- No location tracking (GPS used only on-demand for SOS and friend sharing)
- No analytics on message content

## Supported Versions

| Version | Supported |
|---|---|
| Development (current) | Yes |

## Dependencies

| Dependency | Purpose | Trust Basis |
|---|---|---|
| CryptoKit | Curve25519, ChaChaPoly, SHA256 | Apple first-party |
| swift-sodium | Ed25519 signing | libsodium wrapper, widely audited |
| swift-opus | Audio codec | Opus standard, widely audited |
