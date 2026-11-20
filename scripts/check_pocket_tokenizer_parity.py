#!/usr/bin/env python3
"""Offline reference parity fixture. Never uploads model or audio."""
import argparse
from collections import defaultdict
import sentencepiece as spm

def varint(buf, offset):
    val, shift = 0, 0
    while offset < len(buf) and shift < 70:
        v = buf[offset]; offset += 1
        val |= (v & 127) << shift
        if not (v & 128): return val, offset
        shift += 7
    raise ValueError("Bad protobuf varint")

def fields(buf):
    pos = 0
    while pos < len(buf):
        tag, pos = varint(buf, pos)
        field, kind = tag >> 3, tag & 7
        if kind == 0:
            val, pos = varint(buf, pos)
        elif kind == 2:
            n, pos = varint(buf, pos)
            if n > len(buf)-pos: raise ValueError("Bad protobuf size")
            val = buf[pos:pos+n]; pos += n
        elif kind == 5:
            val = None; pos += 4
        elif kind == 1:
            val = None; pos += 8
        else: raise ValueError("Unsupported protobuf type")
        if pos > len(buf): raise ValueError("Truncated proto")
        yield field, kind, val

def model_type(data):
    kind = 1
    for field, wire, value in fields(data):
        if field == 2 and wire == 2:
            for sub, swire, sv in fields(value):
                if sub == 3 and swire == 0: kind = sv
    return kind

def kotlin_equivalent(sp, raw, kind):
    tokens = {sp.id_to_piece(i): (i,sp.get_score(i))
              for i in range(sp.get_piece_size())
              if not (sp.is_unknown(i) or sp.is_control(i) or sp.is_unused(i))}
    src = "▁" + "▁".join(raw.strip().split())
    if kind == 2:
        parts = list(src)
        if any(x not in tokens for x in parts): raise ValueError("Unsupported character")
        while len(parts)>1:
            ix, best = -1, float("-inf")
            for k in range(len(parts)-1):
                pair = tokens.get(parts[k]+parts[k+1])
                if pair is not None and pair[1] > best: ix,best = k,pair[1]
            if ix<0: break
            parts[ix:ix+2] = [parts[ix]+parts[ix+1]]
        return [tokens[x][0] for x in parts]
    if kind != 1: raise ValueError("Unsupported SentencePiece type")
    first=defaultdict(list)
    for piece,(ident,score) in tokens.items(): first[piece[0]].append((piece,ident,score))
    scores = [float("-inf")]*(len(src)+1)
    path = [None]*(len(src)+1)
    scores[0] = 0.0
    for pos in range(len(src)):
        if scores[pos]==float("-inf"):continue
        found = False
        for piece,ident,score in first.get(src[pos],()):
            if src.startswith(piece,pos):
                stop=pos+len(piece)
                if scores[pos]+score>scores[stop]:
                    scores[stop]=scores[pos]+score
                    path[stop]=(pos,ident)
                found=True
        if not found: raise ValueError("Unknown phoneme character")
    out=[]
    pos=len(src)
    while pos:
        if path[pos] is None: raise ValueError("No token path")
        pos,item = path[pos];out.append(item)
    return list(reversed(out))

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--tokenizer",required=True)
    args=ap.parse_args()
    sp=spm.SentencePieceProcessor(model_file=args.tokenizer)
    with open(args.tokenizer,"rb") as f: kind=model_type(f.read())
    samples=[
        "sAlAm","?emruz havA xeyli xub ?ast",
        "sAlAm hAle SomA CetOre","be xAne miravam",
        "qAbele ?e?temAd","va dar ?in zamAn","SArj batari",
        "mikonad mikonand","?az mAdar","ketAbhAye fArsi",
        "mAdar ketAb rA ruye miz gozASte",
        "sAdeqAne","?e?tesAd","be dArAvAd","in ketAb",
    ]
    mismatches=[]
    for sample in samples:
        expected=sp.encode(sample,out_type=int)
        try:actual=kotlin_equivalent(sp,sample,kind)
        except ValueError as exc: actual=str(exc)
        if expected!=actual:mismatches.append((sample,expected,actual))
    print("Official tokenizer type:",kind,"vocab:",sp.get_piece_size())
    print("matching:",len(samples)-len(mismatches),"/",len(samples))
    for value in mismatches[:5]:print("MISMATCH",value)
    if mismatches:raise SystemExit(1)
    print("PASS: reference IDs match Kotlin port algorithm for fixture; no audio inference")

if __name__=="__main__": main()
