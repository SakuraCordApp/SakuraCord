import CLibdave

class Welcome {
    private let handle: DAVEWelcomeResultHandle

    init(handle: DAVEWelcomeResultHandle) {
        self.handle = handle
    }

    deinit {
        daveWelcomeResultDestroy(self.handle)
    }
}
