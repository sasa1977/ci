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

	program, err := startProgram(args, dir, terminateCmdPart)
	if err == nil {
		writePacket(os.Stdout, []byte("started"))
	} else {
		writePacket(os.Stdout, []byte(fmt.Sprintf("not started %s", err)))
		os.Exit(-1)
	}

	select {
	case <-startStdinReader():
		program.stop()

	case exit := <-program.exitStatus:
		os.Exit(exit)
	}
}
