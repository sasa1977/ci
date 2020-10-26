package main

import (
	"bytes"
	"encoding/binary"
)

type erlangTerm interface {
	writeBytes(buf *bytes.Buffer)
}

type erlangAtom struct {
	value string
}

type erlangBinary struct {
	value []byte
}

type erlangTuple struct {
	elements []erlangTerm
}

func tuple(terms ...erlangTerm) erlangTuple {
	return erlangTuple{elements: terms}
}

func atom(value string) erlangAtom {
	return erlangAtom{value: value}
}

func bin(value string) erlangBinary {
	return erlangBinary{value: []byte(value)}
}

func (atom erlangAtom) writeBytes(buf *bytes.Buffer) {
	// https://erlang.org/doc/apps/erts/erl_ext_dist.html#small_atom_utf8_ext
	buf.WriteByte(119)
	buf.WriteByte(byte(len(atom.value)))
	buf.WriteString(atom.value)
}

func (tuple erlangTuple) writeBytes(buf *bytes.Buffer) {
	// https://erlang.org/doc/apps/erts/erl_ext_dist.html#small_tuple_ext
	buf.WriteByte(104)
	buf.WriteByte(byte(len(tuple.elements)))
	for _, element := range tuple.elements {
		element.writeBytes(buf)
	}
}

func (bin erlangBinary) writeBytes(buf *bytes.Buffer) {
	// https://erlang.org/doc/apps/erts/erl_ext_dist.html#binary_ext
	buf.WriteByte(109)
	binary.Write(buf, binary.BigEndian, int32(len(bin.value)))
	buf.Write(bin.value)
}

func erlangTermBytes(term erlangTerm) []byte {
	// https://erlang.org/doc/apps/erts/erl_ext_dist.html#introduction
	buf := new(bytes.Buffer)
	buf.WriteByte(131)
	term.writeBytes(buf)
	return buf.Bytes()
}
