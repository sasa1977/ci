package main

import (
	"flag"
	"fmt"
	"os"
)

type arrayFlags []string

func (arrayFlags *arrayFlags) String() string {
	strings := []string(*arrayFlags)
	return fmt.Sprintf("%v", strings)
}

func (arrayFlags *arrayFlags) Set(value string) error {
	*arrayFlags = append(*arrayFlags, value)
	return nil
}

func main() {
	dir := flag.String("dir", ".", "working directory")

	var terminateCmdPart arrayFlags
	flag.Var(&terminateCmdPart, "terminate-cmd-part", "terminate command part")

	flag.Parse()
	args := flag.Args()

	stdoutWriter := startStdoutWriter()
	program, err := startProgram(args, dir, terminateCmdPart, stdoutWriter)
	if err == nil {
		stdoutWriter.sendOutput([]byte("started"))
	} else {
		stdoutWriter.sendOutput([]byte(fmt.Sprintf("not started %s", err)))
		os.Exit(-1)
	}

	select {
	case <-startStdinReader():
		go program.stop()
		exitStatus := <-program.exitStatus
		os.Exit(exitStatus)

	case exitStatus := <-program.exitStatus:
		os.Exit(exitStatus)
	}
}
