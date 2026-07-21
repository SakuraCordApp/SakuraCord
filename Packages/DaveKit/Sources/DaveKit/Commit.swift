import CLibdave

class Commit {
    private let handle: DAVECommitResultHandle

    init(handle: DAVECommitResultHandle) {
        self.handle = handle
    }

    deinit {
        daveCommitResultDestroy(self.handle)
    }

    var isFailed: Bool {
        daveCommitResultIsFailed(handle)
    }

    var isIgnored: Bool {
        daveCommitResultIsIgnored(handle)
    }
}
