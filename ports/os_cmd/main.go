package main

import (
	"flag"
	"fmt"
	"os"
)

func main() {
	dir := flag.String("dir", ".", "working directory")
	killCmd := flag.String("kill_cmd", "", "working directory")

	flag.Parse()
	args := flag.Args()

	program, err := startProgram(args, dir, killCmd)
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
