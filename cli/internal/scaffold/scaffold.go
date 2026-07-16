package scaffold

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"syscall"

	"github.com/ggyy0515/AppPilot/internal/contract"
	"golang.org/x/sys/unix"
)

const projectConfig = "port = 9876\noutput_dir = \".ap-ios-debug/artifacts\"\n"

type FilePlan struct {
	Source string      `json:"-"`
	Path   string      `json:"path"`
	Status string      `json:"status"`
	Mode   fs.FileMode `json:"-"`

	contents []byte
}

type ScaffoldPlan struct {
	root        string
	packagePath string
	files       []FilePlan
	xcodeSteps  []string
}

type ScaffoldResult struct {
	Root        string     `json:"root"`
	PackagePath string     `json:"package_path"`
	DryRun      bool       `json:"dry_run"`
	Files       []FilePlan `json:"files"`
	XcodeSteps  []string   `json:"xcode_steps"`
}

func Plan(into string, locator Locator) (ScaffoldPlan, error) {
	root, err := filepath.Abs(into)
	if err != nil {
		return ScaffoldPlan{}, contract.New(contract.IOFailure, err)
	}
	templateRoot, err := locator.Locate()
	if err != nil {
		return ScaffoldPlan{}, err
	}
	templateRoot, err = filepath.Abs(templateRoot)
	if err != nil {
		return ScaffoldPlan{}, contract.New(contract.IOFailure, err)
	}

	packagePath := filepath.Join(root, "DebugTools", "ap-ios-debug-kit")
	if err := validateDestinationAncestors(root, filepath.Join(packagePath, "Package.swift")); err != nil {
		return ScaffoldPlan{}, err
	}
	files, err := templateFiles(templateRoot, packagePath)
	if err != nil {
		return ScaffoldPlan{}, err
	}
	bootstrapSource := filepath.Join(templateRoot, "Templates", "APIOSDebugBootstrap.swift")
	bootstrap, err := sourceFilePlan(bootstrapSource, filepath.Join(root, "DebugTools", "APIOSDebugBootstrap.swift"))
	if err != nil {
		return ScaffoldPlan{}, err
	}
	files = append(files, bootstrap)
	configuration := FilePlan{
		Path:     filepath.Join(root, ".ap-ios-debug.toml"),
		Mode:     0o600,
		contents: []byte(projectConfig),
	}
	configuration.Status, err = compareDestination(configuration.Path, configuration.contents)
	if err != nil {
		return ScaffoldPlan{}, err
	}
	files = append(files, configuration)
	for _, file := range files {
		if err := validateDestinationAncestors(root, file.Path); err != nil {
			return ScaffoldPlan{}, err
		}
	}
	sort.Slice(files, func(i, j int) bool { return files[i].Path < files[j].Path })

	return ScaffoldPlan{
		root:        root,
		packagePath: packagePath,
		files:       files,
		xcodeSteps: []string{
			"In Xcode, select File > Add Package Dependencies…",
			"Click Add Local… and choose " + packagePath + ".",
			"Add the APIOSDebugKit product only to a dedicated Debug app target; keep every Release or production target free of this package dependency.",
			"Add " + filepath.Join(root, "DebugTools", "APIOSDebugBootstrap.swift") + " only to the dedicated Debug app target, call try await APIOSDebugBootstrap.start() at Debug startup, and call await APIOSDebugBootstrap.stop() later at shutdown.",
		},
	}, nil
}

func (p ScaffoldPlan) Result(dryRun bool) ScaffoldResult {
	files := make([]FilePlan, len(p.files))
	for index, file := range p.files {
		file.contents = append([]byte(nil), file.contents...)
		files[index] = file
	}
	return ScaffoldResult{
		Root:        p.root,
		PackagePath: p.packagePath,
		DryRun:      dryRun,
		Files:       files,
		XcodeSteps:  append([]string(nil), p.xcodeSteps...),
	}
}

func Apply(plan ScaffoldPlan) (ScaffoldResult, error) {
	return applyWithCommitHook(plan, nil)
}

func applyWithCommitHook(plan ScaffoldPlan, beforeCommit func(string) error) (ScaffoldResult, error) {
	refreshed := plan
	refreshed.files = make([]FilePlan, len(plan.files))
	for index, file := range plan.files {
		if err := validateDestinationAncestors(plan.root, file.Path); err != nil {
			return ScaffoldResult{}, err
		}
		file.contents = append([]byte(nil), file.contents...)
		var err error
		file.Status, err = compareDestination(file.Path, file.contents)
		if err != nil {
			return ScaffoldResult{}, err
		}
		refreshed.files[index] = file
	}
	for _, file := range refreshed.files {
		if file.Status == "conflict" {
			return ScaffoldResult{}, contract.NewWithHint(contract.ConfigInvalid, nil, "Remove or reconcile every reported conflict, then rerun app scaffold.")
		}
	}
	transaction, err := stageFiles(refreshed)
	if err != nil {
		return ScaffoldResult{}, err
	}
	defer os.RemoveAll(transaction.directory)
	if err := commitFiles(refreshed, transaction, beforeCommit); err != nil {
		return ScaffoldResult{}, err
	}
	return refreshed.Result(false), nil
}

// InitLocal creates the single project-local configuration managed by init --local.
func InitLocal(root string) (FilePlan, error) {
	absoluteRoot, err := filepath.Abs(root)
	if err != nil {
		return FilePlan{}, contract.New(contract.IOFailure, err)
	}
	file := FilePlan{Path: filepath.Join(absoluteRoot, ".ap-ios-debug.toml"), Mode: 0o600, contents: []byte(projectConfig)}
	if err := validateDestinationAncestors(absoluteRoot, file.Path); err != nil {
		return FilePlan{}, err
	}
	file.Status, err = compareDestination(file.Path, file.contents)
	if err != nil {
		return FilePlan{}, err
	}
	if file.Status == "conflict" {
		return FilePlan{}, contract.NewWithHint(contract.ConfigInvalid, nil, "Remove or reconcile .ap-ios-debug.toml, then rerun ap-ios-debug init --local.")
	}
	result, err := applyWithCommitHook(ScaffoldPlan{root: absoluteRoot, files: []FilePlan{file}}, nil)
	if err != nil {
		return FilePlan{}, err
	}
	return result.Files[0], nil
}

func templateFiles(sourceRoot, destinationRoot string) ([]FilePlan, error) {
	var files []FilePlan
	err := filepath.WalkDir(sourceRoot, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if path == sourceRoot {
			if !entry.IsDir() {
				return fs.ErrInvalid
			}
			return nil
		}
		relative, err := filepath.Rel(sourceRoot, path)
		if err != nil {
			return err
		}
		if excluded(relative) {
			if entry.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() && !info.Mode().IsRegular() {
			return fs.ErrInvalid
		}
		if info.IsDir() {
			return nil
		}
		file, err := sourceFilePlan(path, filepath.Join(destinationRoot, relative))
		if err != nil {
			return err
		}
		files = append(files, file)
		return nil
	})
	if err != nil {
		return nil, contract.New(contract.IOFailure, err)
	}
	return files, nil
}

func excluded(relative string) bool {
	for _, component := range strings.Split(filepath.ToSlash(relative), "/") {
		if component == ".build" || component == ".swiftpm" {
			return true
		}
	}
	return false
}

func sourceFilePlan(source, destination string) (FilePlan, error) {
	info, err := os.Lstat(source)
	if err != nil || !info.Mode().IsRegular() {
		return FilePlan{}, contract.New(contract.IOFailure, err)
	}
	contents, err := os.ReadFile(source)
	if err != nil {
		return FilePlan{}, contract.New(contract.IOFailure, err)
	}
	status, err := compareDestination(destination, contents)
	if err != nil {
		return FilePlan{}, err
	}
	return FilePlan{Source: source, Path: destination, Status: status, Mode: info.Mode().Perm(), contents: contents}, nil
}

func compareDestination(path string, expected []byte) (string, error) {
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return "create", nil
	}
	if err != nil {
		return "", contract.New(contract.IOFailure, err)
	}
	if !info.Mode().IsRegular() {
		return "conflict", nil
	}
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_NOFOLLOW, 0)
	if err != nil {
		return "", contract.New(contract.IOFailure, err)
	}
	file := os.NewFile(uintptr(fd), path)
	actual, readErr := io.ReadAll(file)
	closeErr := file.Close()
	if readErr != nil {
		return "", contract.New(contract.IOFailure, readErr)
	}
	if closeErr != nil {
		return "", contract.New(contract.IOFailure, closeErr)
	}
	finalInfo, err := os.Lstat(path)
	if err != nil || !os.SameFile(info, finalInfo) || !finalInfo.Mode().IsRegular() {
		return "", contract.New(contract.IOFailure, fs.ErrInvalid)
	}
	if bytes.Equal(actual, expected) {
		return "unchanged", nil
	}
	return "conflict", nil
}

func validateDestinationAncestors(root, destination string) error {
	if !filepath.IsAbs(root) || !filepath.IsAbs(destination) {
		return contract.New(contract.IOFailure, fs.ErrInvalid)
	}
	root = filepath.Clean(root)
	destination = filepath.Clean(destination)
	relativeParent, err := filepath.Rel(root, filepath.Dir(destination))
	if err != nil || relativeParent == ".." || strings.HasPrefix(relativeParent, ".."+string(filepath.Separator)) {
		return contract.New(contract.IOFailure, fs.ErrInvalid)
	}
	if err := validateExistingDirectoryAncestors(root); err != nil {
		return err
	}
	return validateExistingDirectoryAncestors(filepath.Dir(destination))
}

func validateExistingDirectoryAncestors(path string) error {
	path = filepath.Clean(path)
	if !filepath.IsAbs(path) {
		return contract.New(contract.IOFailure, fs.ErrInvalid)
	}
	// Darwin exposes /tmp and /var through root-owned platform aliases. Only
	// canonicalize aliases whose ownership and exact targets are verified;
	// every ordinary symlink below those anchors remains forbidden.
	path = canonicalValidationPath(path)
	volume := filepath.VolumeName(path)
	current := volume + string(filepath.Separator)
	relative := strings.TrimPrefix(path, current)
	components := []string{}
	if relative != "" {
		components = strings.Split(relative, string(filepath.Separator))
	}
	paths := append([]string{current}, components...)
	for index, component := range paths {
		if index > 0 {
			current = filepath.Join(current, component)
		}
		info, err := os.Lstat(current)
		if os.IsNotExist(err) {
			return nil
		}
		if err != nil {
			return contract.New(contract.IOFailure, err)
		}
		if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
			return contract.New(contract.IOFailure, fs.ErrInvalid)
		}
	}
	return nil
}

type stagedTransaction struct {
	directory string
	files     map[string]string
}

func stageFiles(plan ScaffoldPlan) (stagedTransaction, error) {
	parent := filepath.Dir(plan.root)
	if err := validateExistingDirectoryAncestors(parent); err != nil {
		return stagedTransaction{}, err
	}
	directory, err := os.MkdirTemp(parent, ".ap-ios-debug-scaffold-*")
	if err != nil {
		return stagedTransaction{}, contract.New(contract.IOFailure, err)
	}
	transaction := stagedTransaction{directory: directory, files: make(map[string]string)}
	ok := false
	defer func() {
		if !ok {
			_ = os.RemoveAll(directory)
		}
	}()
	for index, file := range plan.files {
		if file.Status != "create" {
			continue
		}
		staged := filepath.Join(directory, fmt.Sprintf("%06d", index))
		if err := writeStagedFile(staged, file.contents, file.Mode); err != nil {
			return stagedTransaction{}, err
		}
		transaction.files[file.Path] = staged
	}
	dir, err := os.Open(directory)
	if err != nil {
		return stagedTransaction{}, contract.New(contract.IOFailure, err)
	}
	syncErr := dir.Sync()
	closeErr := dir.Close()
	if syncErr != nil {
		return stagedTransaction{}, contract.New(contract.IOFailure, syncErr)
	}
	if closeErr != nil {
		return stagedTransaction{}, contract.New(contract.IOFailure, closeErr)
	}
	ok = true
	return transaction, nil
}

func writeStagedFile(path string, contents []byte, mode fs.FileMode) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode.Perm())
	if err != nil {
		return contract.New(contract.IOFailure, err)
	}
	ok := false
	defer func() {
		_ = file.Close()
		if !ok {
			_ = os.Remove(path)
		}
	}()
	if _, err := file.Write(contents); err != nil {
		return contract.New(contract.IOFailure, err)
	}
	if err := file.Chmod(mode.Perm()); err != nil {
		return contract.New(contract.IOFailure, err)
	}
	if err := file.Sync(); err != nil {
		return contract.New(contract.IOFailure, err)
	}
	if err := file.Close(); err != nil {
		return contract.New(contract.IOFailure, err)
	}
	ok = true
	return nil
}

type createdPath struct {
	path string
	info fs.FileInfo
}

func commitFiles(plan ScaffoldPlan, transaction stagedTransaction, beforeCommit func(string) error) (err error) {
	createdFiles := []createdPath{}
	createdDirectories := []createdPath{}
	committed := false
	defer func() {
		if committed {
			return
		}
		for index := len(createdFiles) - 1; index >= 0; index-- {
			removeIfSame(createdFiles[index])
		}
		for index := len(createdDirectories) - 1; index >= 0; index-- {
			removeIfSame(createdDirectories[index])
		}
	}()
	for _, file := range plan.files {
		if file.Status != "create" {
			continue
		}
		if err := validateDestinationAncestors(plan.root, file.Path); err != nil {
			return err
		}
		newDirectories, err := ensureDestinationDirectories(plan.root, filepath.Dir(file.Path))
		createdDirectories = append(createdDirectories, newDirectories...)
		if err != nil {
			return err
		}
		if beforeCommit != nil {
			if err := beforeCommit(file.Path); err != nil {
				return contract.New(contract.IOFailure, err)
			}
		}
		if err := validateDestinationAncestors(plan.root, file.Path); err != nil {
			return err
		}
		staged := transaction.files[file.Path]
		stagedInfo, statErr := os.Lstat(staged)
		if statErr != nil {
			return contract.New(contract.IOFailure, statErr)
		}
		parent, openErr := openDirectoryNoFollow(filepath.Dir(file.Path))
		if openErr != nil {
			return openErr
		}
		linkErr := unix.Linkat(unix.AT_FDCWD, staged, int(parent.Fd()), filepath.Base(file.Path), 0)
		closeErr := parent.Close()
		if linkErr != nil {
			return contract.New(contract.IOFailure, linkErr)
		}
		createdFiles = append(createdFiles, createdPath{path: file.Path, info: stagedInfo})
		if closeErr != nil {
			return contract.New(contract.IOFailure, closeErr)
		}
		if err := validateDestinationAncestors(plan.root, file.Path); err != nil {
			return err
		}
	}
	if err := syncCommittedDirectories(plan, createdDirectories); err != nil {
		return err
	}
	committed = true
	return nil
}

func syncCommittedDirectories(plan ScaffoldPlan, createdDirectories []createdPath) error {
	directories := make(map[string]struct{})
	for _, file := range plan.files {
		if file.Status == "create" {
			directories[filepath.Dir(file.Path)] = struct{}{}
		}
	}
	for _, directory := range createdDirectories {
		directories[filepath.Dir(directory.path)] = struct{}{}
	}
	ordered := make([]string, 0, len(directories))
	for directory := range directories {
		ordered = append(ordered, directory)
	}
	sort.Strings(ordered)
	for _, directory := range ordered {
		if err := validateExistingDirectoryAncestors(directory); err != nil {
			return err
		}
		file, err := openDirectoryNoFollow(directory)
		if err != nil {
			return err
		}
		syncErr := file.Sync()
		closeErr := file.Close()
		if syncErr != nil {
			return contract.New(contract.IOFailure, syncErr)
		}
		if closeErr != nil {
			return contract.New(contract.IOFailure, closeErr)
		}
	}
	return nil
}

func ensureDestinationDirectories(root, destinationDirectory string) ([]createdPath, error) {
	base := filepath.Dir(root)
	relative, err := filepath.Rel(base, destinationDirectory)
	if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return nil, contract.New(contract.IOFailure, fs.ErrInvalid)
	}
	currentPath := base
	created := []createdPath{}
	current, err := openDirectoryNoFollow(base)
	if err != nil {
		return created, err
	}
	defer func() { _ = current.Close() }()
	for _, component := range strings.Split(relative, string(filepath.Separator)) {
		if component == "." || component == "" {
			continue
		}
		currentPath = filepath.Join(currentPath, component)
		fd, openErr := unix.Openat(int(current.Fd()), component, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW, 0)
		wasCreated := false
		if errors.Is(openErr, unix.ENOENT) {
			if mkdirErr := unix.Mkdirat(int(current.Fd()), component, 0o755); mkdirErr != nil {
				return created, contract.New(contract.IOFailure, mkdirErr)
			}
			wasCreated = true
			fd, openErr = unix.Openat(int(current.Fd()), component, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW, 0)
		}
		if openErr != nil {
			return created, contract.New(contract.IOFailure, openErr)
		}
		next := os.NewFile(uintptr(fd), currentPath)
		info, statErr := next.Stat()
		if statErr != nil {
			_ = next.Close()
			return created, contract.New(contract.IOFailure, statErr)
		}
		if wasCreated {
			created = append(created, createdPath{path: currentPath, info: info})
		}
		_ = current.Close()
		current = next
	}
	return created, nil
}

func canonicalValidationPath(path string) string {
	return canonicalValidationPathWith(path, runtime.GOOS, trustedDarwinSystemAlias)
}

func canonicalValidationPathWith(path, goos string, trusted func(string, string) bool) string {
	if goos != "darwin" {
		return path
	}
	for _, alias := range []struct {
		path   string
		target string
	}{
		{path: "/tmp", target: "/private/tmp"},
		{path: "/var", target: "/private/var"},
	} {
		if (path == alias.path || strings.HasPrefix(path, alias.path+string(filepath.Separator))) && trusted(alias.path, alias.target) {
			return alias.target + strings.TrimPrefix(path, alias.path)
		}
	}
	return path
}

func trustedDarwinSystemAlias(alias, expectedTarget string) bool {
	return trustedDarwinSystemAliasWith(alias, expectedTarget, func(path string) (fs.FileMode, uint32, error) {
		info, err := os.Lstat(path)
		if err != nil {
			return 0, 0, err
		}
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok {
			return 0, 0, fs.ErrInvalid
		}
		return info.Mode(), stat.Uid, nil
	}, filepath.EvalSymlinks)
}

func trustedDarwinSystemAliasWith(
	alias string,
	expectedTarget string,
	metadata func(string) (fs.FileMode, uint32, error),
	resolve func(string) (string, error),
) bool {
	mode, uid, err := metadata(alias)
	if err != nil || mode&os.ModeSymlink == 0 || uid != 0 {
		return false
	}
	resolved, err := resolve(alias)
	return err == nil && resolved == expectedTarget
}

func openDirectoryNoFollow(path string) (*os.File, error) {
	path = canonicalValidationPath(filepath.Clean(path))
	if !filepath.IsAbs(path) {
		return nil, contract.New(contract.IOFailure, fs.ErrInvalid)
	}
	volume := filepath.VolumeName(path)
	root := volume + string(filepath.Separator)
	fd, err := unix.Open(root, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW, 0)
	if err != nil {
		return nil, contract.New(contract.IOFailure, err)
	}
	current := os.NewFile(uintptr(fd), root)
	relative := strings.TrimPrefix(path, root)
	if relative == "" {
		return current, nil
	}
	for _, component := range strings.Split(relative, string(filepath.Separator)) {
		nextFD, openErr := unix.Openat(int(current.Fd()), component, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW, 0)
		if openErr != nil {
			_ = current.Close()
			return nil, contract.New(contract.IOFailure, openErr)
		}
		_ = current.Close()
		current = os.NewFile(uintptr(nextFD), component)
	}
	return current, nil
}

func removeIfSame(created createdPath) {
	current, err := os.Lstat(created.path)
	if err == nil && os.SameFile(current, created.info) {
		_ = os.Remove(created.path)
	}
}
