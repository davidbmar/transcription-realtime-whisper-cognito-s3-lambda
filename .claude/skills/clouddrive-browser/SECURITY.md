# Security Notes for CloudDrive Browser Skill

## Credential Storage Approach

### How It Works

1. **First Run**: If credentials are not found in `.env`, the script prompts:
   ```
   Email: your-email@example.com
   Password: ••••••••••
   ```

2. **Auto-Save**: Credentials are saved to `.env` file:
   ```bash
   CLOUDDRIVE_TEST_EMAIL=your-email@example.com
   CLOUDDRIVE_TEST_PASSWORD=your-password
   ```

3. **Gitignored**: `.env` is in `.gitignore` and NEVER committed to git

4. **Reuse**: Subsequent runs read from `.env` (no re-prompting)

### Security Considerations

#### ✅ What's Secure

- **Not in Git**: `.env` is gitignored - credentials never go to repository
- **No Hardcoding**: No usernames/passwords in source code
- **Per-Developer**: Each developer has their own `.env` with their credentials
- **Standard Practice**: Using `.env` for secrets is industry standard for development

#### ⚠️ Limitations

**1. Plain Text Storage**
- Passwords are stored in **plain text** in `.env` file
- Anyone with file system access can read them
- Not encrypted at rest

**2. No Rotation**
- Passwords don't auto-rotate
- Must manually update if changed

**3. Local Machine Only**
- Only as secure as your local machine
- If machine is compromised, credentials are exposed

### Is This Secure?

**For Development/Testing: YES** ✅
- Standard practice for dev tools
- Same approach used by AWS CLI, Docker, npm, etc.
- Better than hardcoding or prompting every time

**For Production: NO** ❌
- Don't use this approach for production systems
- Production should use:
  - AWS Secrets Manager
  - HashiCorp Vault
  - Cloud provider secret stores
  - OAuth tokens with short TTLs

### Better Alternatives (If Needed)

If you want more security, consider:

#### 1. System Keychain (Most Secure)
```bash
# macOS Keychain
security add-generic-password -s "clouddrive" -a "$USER" -w "password"

# Linux libsecret
secret-tool store --label='CloudDrive' service clouddrive username your-email
```

#### 2. Environment Variables Only (No File)
```bash
# Set in shell session (not persisted)
export CLOUDDRIVE_TEST_EMAIL=user@example.com
export CLOUDDRIVE_TEST_PASSWORD=password
./test-login.sh
```

#### 3. Dedicated Test Account
- Create `test@yourdomain.com` account
- Use only for automation (not personal account)
- Rotate password regularly
- Limit permissions if possible

### Recommendations

**For This Skill:**
1. ✅ Use `.env` for convenience (it's development-only)
2. ✅ Never commit `.env` to git (already gitignored)
3. ✅ Use a dedicated test account (not your main account)
4. ✅ Rotate test password occasionally
5. ✅ Ensure file permissions are restrictive:
   ```bash
   chmod 600 .env  # Only you can read/write
   ```

**What We've Done:**
- ✅ Removed all hardcoded credentials from source
- ✅ Made .env gitignored
- ✅ Auto-prompt on first run
- ✅ Created .env.example (safe to commit)
- ✅ Documented security trade-offs

### File Permissions

Restrict `.env` file access:

```bash
# Only owner can read/write
chmod 600 .env

# Verify
ls -la .env
# Should show: -rw------- (600)
```

### Audit Trail

Check if your credentials were ever committed:

```bash
# Search git history for email
git log -p -S "your-email@example.com"

# Search for password patterns (be careful!)
git log -p --all | grep -i "password"

# If found, you need to:
# 1. Remove from history (git filter-branch)
# 2. Force push (careful!)
# 3. Rotate credentials immediately
```

### CI/CD Considerations

If running in CI/CD:

```yaml
# GitHub Actions example
- name: Run browser tests
  env:
    CLOUDDRIVE_TEST_EMAIL: ${{ secrets.TEST_EMAIL }}
    CLOUDDRIVE_TEST_PASSWORD: ${{ secrets.TEST_PASSWORD }}
  run: ./test-workflow.sh
```

**Never** put credentials in:
- ❌ GitHub Actions yaml files
- ❌ README or documentation
- ❌ Shell history (use `HISTIGNORE`)
- ❌ Log files
- ❌ Screenshots or error messages

### Quick Security Checklist

Before committing:
- [ ] `.env` is in `.gitignore`
- [ ] No passwords in source code
- [ ] No passwords in commit messages
- [ ] `.env.example` has placeholders only
- [ ] README doesn't contain real credentials
- [ ] `git status` doesn't show `.env`

## Summary

**This approach is secure enough for:**
- ✅ Local development
- ✅ Testing automation
- ✅ Developer tools
- ✅ Non-production environments

**This approach is NOT secure enough for:**
- ❌ Production systems
- ❌ Sensitive customer data
- ❌ Compliance requirements (SOC2, HIPAA, etc.)
- ❌ Shared machines
- ❌ Untrusted environments

For this skill (CloudDrive browser testing), the `.env` approach strikes the right balance between security and usability.
