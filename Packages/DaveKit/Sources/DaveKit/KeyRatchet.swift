import CLibdave

class KeyRatchet {
    let handle: DAVEKeyRatchetHandle

    init(handle: DAVEKeyRatchetHandle) {
        self.handle = handle
    }

    deinit {
        daveKeyRatchetDestroy(self.handle)
    }
}
