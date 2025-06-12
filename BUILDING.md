It looks like you're working with a **containerization project** (possibly related to macOS system containers or Docker-like functionality) that requires specific build steps. Here's a structured guide to help you navigate the process:

---

### **1. Prerequisites**
Ensure your system meets these requirements:
- **macOS 15+** (or **macOS 26 Beta 1+**)
- **Xcode 26 Beta** (for development)
- **Command Line Tools** installed:
  ```bash
  xcode-select --install
  ```

---

### **2. Build & Test**
#### **Compile and Run Tests**
```bash
# Build the project and run tests
make all test integration
```

#### **Install Binaries**
```bash
# Copy binaries to system directories (requires sudo)
make install
```
*Note:* This installs to `/usr/local/bin` and `/usr/local/libexec`.

---

### **3. gRPC/Protobuf Compilation**
If you modify gRPC APIs (e.g., in `container-builder-shim`):
```bash
# Regenerate gRPC/protobuf code
make protos
```
*Requirements:*
- Install `protoc` (Protocol Buffers compiler)
- Ensure `grpc-swift` and `swift-protobuf` versions match the project's needs.

---

### **4. Local Development with Containerization**
To co-develop with the `Containerization` dependency:

#### **Set Up Workspace**
```bash
# Clone both repos side-by-side
git clone https://github.com/your/container.git
git clone https://github.com/your/containerization.git
cd container
```

#### **Link Local Containerization**
```bash
# Stop running services
bin/container system stop

# Point to local Containerization
export CONTAINERIZATION_PATH=../containerization
swift package update containerization

# Rebuild Containerization
(cd ${CONTAINERIZATION_PATH} && make clean all)

# Rebuild container
make clean all

# Restart services
bin/container system start
```

#### **Revert to Remote Dependency**
```bash
unset CONTAINERIZATION_PATH
swift package update containerization
make clean all
bin/container system start
```

---

### **5. Key Directories & Files**
| Path                     | Purpose                          |
|--------------------------|----------------------------------|
| `/usr/local/bin`         | Installed binaries               |
| `/usr/local/libexec`     | Helper executables               |
| `Package.swift`          | Swift package manager config     |
| `bin/container`          | Control scripts for services     |

---

### **Troubleshooting**
- **Build Failures**:  
  - Ensure Xcode Beta is selected:  
    ```bash
    sudo xcode-select -s /Applications/Xcode-beta.app
    ```
  - Clean derived data:  
    ```bash
    rm -rf ~/Library/Developer/Xcode/DerivedData/
    ```

- **gRPC Errors**:  
  Verify `protoc` version matches the project's requirements.

- **Permission Issues**:  
  Use `sudo` for `make install` and ensure your user has admin rights.

---

### **Next Steps**
1. **Customize the Containerization** project if needed.
2. **Extend gRPC APIs** in `container-builder-shim`.
3. **Debug Services**:  
   ```bash
   bin/container system logs  # View service logs
   ```

Let me know if you'd like help with any specific step!
