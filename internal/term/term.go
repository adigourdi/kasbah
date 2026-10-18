// Package term answers the two terminal questions kasbah asks: is this file
// descriptor a terminal (bash's `[ -t N ]`), and can typing on it be hidden
// (`read -s`).
package term

// IsTerminal reports whether fd is a terminal — isatty(3), not "a character
// device": /dev/null is one of those and is not a terminal.
func IsTerminal(fd uintptr) bool {
	_, err := getState(fd)
	return err == nil
}

// NoEcho turns echo off on the terminal at fd and returns what puts it back.
func NoEcho(fd uintptr) (restore func() error, err error) {
	st, err := getState(fd)
	if err != nil {
		return nil, err
	}
	quiet := *st
	quiet.Lflag &^= echoFlag
	if err := setState(fd, &quiet); err != nil {
		return nil, err
	}
	return func() error { return setState(fd, st) }, nil
}
