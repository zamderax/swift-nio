#if os(Windows)
import WinSDK

@inline(__always)
func usleep(_ usecs: UInt32) {
    let milliseconds = (usecs + 999) / 1000
    Sleep(DWORD(milliseconds))
}

@inline(__always)
func usleep(_ usecs: Int) {
    usleep(UInt32(usecs))
}

@inline(__always)
@discardableResult
func sleep(_ seconds: UInt32) -> UInt32 {
    Sleep(DWORD(seconds * 1000))
    return 0
}

@inline(__always)
@discardableResult
func sleep(_ seconds: Int) -> UInt32 {
    sleep(UInt32(seconds))
}
#endif