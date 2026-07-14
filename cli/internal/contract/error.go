package contract

import "errors"

type Code string

const (
	ConfigInvalid              Code = "config_invalid"
	ToolMissing                Code = "tool_missing"
	NoDevice                   Code = "no_device"
	MultipleDevices            Code = "multiple_devices"
	DeviceUntrusted            Code = "device_untrusted"
	DeviceLocked               Code = "device_locked"
	AppNotReachable            Code = "app_not_reachable"
	TransportFailure           Code = "transport_failure"
	RequestTimeout             Code = "request_timeout"
	ProtocolMismatch           Code = "protocol_mismatch"
	AuthRequired               Code = "auth_required"
	AuthFailed                 Code = "auth_failed"
	ActionNotFound             Code = "action_not_found"
	ActionDisabled             Code = "action_disabled"
	ActionFailed               Code = "action_failed"
	ActionRequiresConfirmation Code = "action_requires_confirmation"
	StateEncodingFailed        Code = "state_encoding_failed"
	ScreenshotFailed           Code = "screenshot_failed"
	RecordingNotAvailable      Code = "recording_not_available"
	RecordingInvalidState      Code = "recording_invalid_state"
	RecordingPermissionTimeout Code = "recording_permission_timeout"
	ArtifactTooLarge           Code = "artifact_too_large"
	ArtifactChecksumMismatch   Code = "artifact_checksum_mismatch"
	IOFailure                  Code = "io_failure"
)

type descriptor struct {
	message string
	hint    string
	exit    int
}

var descriptors = map[Code]descriptor{
	ConfigInvalid:              {"Configuration is invalid.", "Fix the named flag, environment variable, or TOML field.", 2},
	ToolMissing:                {"A required developer tool is missing.", "Install Xcode command line tools and select the active Xcode with xcode-select.", 2},
	NoDevice:                   {"No available iOS device was found.", "Connect and unlock one physical iOS device, then run ios-debug --json devices list.", 3},
	MultipleDevices:            {"More than one available iOS device matches.", "Pass --device with a UDID or use devices resolve --name with a unique name.", 3},
	DeviceUntrusted:            {"The device is not paired with this Mac.", "Trust this Mac on the device and retry after pairing completes.", 3},
	DeviceLocked:               {"The device is locked.", "Unlock the device and keep its screen awake while debugging.", 3},
	AppNotReachable:            {"Debug server is not reachable.", "Launch a Debug build, keep the device unlocked, and resume the App if it is paused at a breakpoint.", 4},
	TransportFailure:           {"The device transport failed.", "Reconnect the USB cable, verify the selected UDID, and retry.", 4},
	RequestTimeout:             {"The debug request timed out.", "Resume the App if it is paused at a breakpoint, keep it foregrounded, and retry.", 4},
	ProtocolMismatch:           {"The App debug protocol is incompatible.", "Use an IOSDebugKit build that implements protocol version 1.", 5},
	AuthRequired:               {"The App requires a bearer token.", "Set IOS_DEBUG_TOKEN in this shell and retry.", 5},
	AuthFailed:                 {"The bearer token was rejected.", "Replace IOS_DEBUG_TOKEN with the token configured by the Debug App.", 5},
	ActionNotFound:             {"The action is no longer registered.", "Run ios-debug --json actions list again and use a current identifier.", 5},
	ActionDisabled:             {"The action is currently disabled.", "Inspect App state, wait until the action is enabled, and list actions again.", 5},
	ActionFailed:               {"The registered action failed.", "Inspect App state and Debug logs, correct the action closure, then retry.", 5},
	ActionRequiresConfirmation: {"The action requires explicit confirmation.", "Obtain user approval for the destructive action before activating it.", 5},
	StateEncodingFailed:        {"The App could not encode its state.", "Fix the DebugStateProvider so it emits a complete JSON value.", 5},
	ScreenshotFailed:           {"The App could not capture a screenshot.", "Foreground a window scene and retry the capture.", 5},
	RecordingNotAvailable:      {"Screen recording is not available.", "Check ReplayKit availability and keep the App foregrounded.", 5},
	RecordingInvalidState:      {"The recording command is invalid for the current state.", "Run ios-debug --json recording status before retrying.", 5},
	RecordingPermissionTimeout: {"Screen recording permission timed out.", "Respond to the system prompt within 60 seconds and retry.", 5},
	ArtifactTooLarge:           {"The artifact exceeds the allowed size.", "Reduce the state or recording duration and retry.", 6},
	ArtifactChecksumMismatch:   {"The artifact checksum does not match.", "Retry the download; the completed recording remains on the device for recovery.", 6},
	IOFailure:                  {"The local file operation failed.", "Choose a writable output path with enough free disk space.", 6},
}

type Error struct {
	Code       Code   `json:"code"`
	Message    string `json:"message"`
	Hint       string `json:"hint"`
	cause      error
	trusted    bool
	stableCode Code
	stableHint string
}

func New(code Code, cause error) *Error {
	d, ok := descriptors[code]
	if !ok {
		code = ProtocolMismatch
		d = descriptors[code]
	}
	return &Error{
		Code: code, Message: d.message, Hint: d.hint, cause: cause,
		trusted: true, stableCode: code, stableHint: d.hint,
	}
}

func NewWithHint(code Code, cause error, hint string) *Error {
	result := New(code, cause)
	result.Hint = hint
	result.stableHint = hint
	return result
}

func (e *Error) Error() string {
	return descriptors[CodeOf(e)].message
}

func (e *Error) Unwrap() error {
	return e.cause
}

func CodeOf(err error) Code {
	var target *Error
	if errors.As(err, &target) {
		if target.trusted {
			if _, ok := descriptors[target.stableCode]; ok {
				return target.stableCode
			}
			return ProtocolMismatch
		}
		if _, ok := descriptors[target.Code]; ok {
			return target.Code
		}
	}
	return ProtocolMismatch
}

func canonicalError(err error) *Error {
	var target *Error
	code := CodeOf(err)
	if errors.As(err, &target) && target.trusted {
		return NewWithHint(code, err, target.stableHint)
	}
	return New(code, err)
}

func ExitCode(err error) int {
	d, ok := descriptors[CodeOf(err)]
	if !ok {
		d = descriptors[ProtocolMismatch]
	}
	return d.exit
}
