import CoreGraphics
@testable import displayctl

func makeDisplay(
    id: CGDirectDisplayID = 1,
    name: String = "Studio Display",
    serial: String = "0"
) -> DisplayDevice {
    DisplayDevice(
        id: id,
        name: name,
        vendorID: 0x0610,
        modelID: 0x9d02,
        serialNumber: 0,
        serialText: serial,
        isMain: id == 1,
        isBuiltIn: false,
        isMirrored: false,
        resolution: nil,
        kind: .studioDisplay
    )
}
