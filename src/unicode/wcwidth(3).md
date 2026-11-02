# Kuhn's algorithm
sources: 
- [wcwidth.c](https://sources.debian.org/src/xterm/278-4/wcwidth.c)
- [General_Category](https://www.unicode.org/reports/tr44/#GC_Values_Table)
- [UCD EastAsianWidth.txt v5.0.0](https://www.unicode.org/Public/5.0.0/ucd/EastAsianWidth.txt)
- [UAX #11](https://www.unicode.org/reports/tr11/)

The source explicitly specifies:

P1   U+0000           |  0  |   POSIX/Kuhn
P2   CO/C1 + DEL      | -1  |   POSIX/Kuhn
P3   Mn/Me            |  0  |   Unicode General_Category
P4   U+00AD           |  1  |   Kuhn exception
P5   "Other" Cf       |  0  |   Unicode General_Category
P6   U+200B           |  0  |   Kuhn explicit addition
P7   U+1160..U+11FF   |  0  |   Kuhn explicit addition
P8   EAW W/F          |  2  |   Hard-codeded Unicode UAX #11 (EAW v5.0.0)
P9   everything else  |  1  |   Kuhn default policy

NOTE!
1. On P8, characters in the source’s hard-coded approximation of the Unicode 5.0 East Asian Width 
W/F set return 2.

2. In the original implementation, P5 and P6 are represented together in the `combining[]` table.
The table was generated from: +cat=Me +cat=Mn +cat=Cf -00AD +1160-11FF +200B. So the table is 
precomputed union of those categories and explicit ranges; the function does not independently 
query Unicode General_Category for each character. Also, the function assumes that wchar_t contains
an ISO 10646/Unicode code point and does not explicitly reject values outside the Unicode scalar 
-value range.

That is almost the entire conceptual algorithm. The source states these rules explicitly.

```
combining =
    General_Category = Me
  ∪ General_Category = Mn
  ∪ General_Category = Cf
  − U+00AD
  ∪ U+1160..U+11FF
  ∪ U+200B
  ```

The resulting code then uses binary search in that precomputed interval list. If the input code 
point is found, mk_wcwidth return 0.

NOTE!
1. This is based on the Unicode data available when that version of wcwidth.c was generated. It is 
not dynamically evaluated against the current Unicode General_Category data.
2. U+200B is already a Cf character in modern data, so the explicit +200B is redundant today, but 
it reflects the source's explicit policy and/or the data-generation context.
3. The U+00AD operation applies to the union of the category set, so SOFT HYPHEN is excluded from 
the zero-width table and ultimately receives width 1.

## Kuhn’s CJK alternate policy
mk_wcwidth_cjk() implements Kuhn's CJK alternate policy by adding width 2 to selected East Asian
Ambiguous (A) characters. So, the normal mk_wcwidth() rules stlil apply first conceptually through
the fallback, but characters in the ambiguous[] table are overridden to width 2.

The source's ambiguous set is generated approximately as

```
ambiguous = 
    +WIDTH-A
    -cat=Me
    -cat=Mn
    -cat=Cf
    +private-use ranges (+E000..F8FF, +F0000..FFFFD, +100000..10FFFD)
```


Therefore, the effective policy is become
```
mk_wcwidth_cjk(ucs):
    if ucs is an EAW-Ambiguous character
       and it is not a combining/format character
       and it is not U+00AD:
        return 2
    else
        return mk_wcwidth(ucs)

NOTE!
1. WIDTH-A is a separately generated liist of characters whose East Asian Width is A. The source 
additionally says that U+00AD and lines COMBINING were omitted from that input.
2. The alternate function treats these ranges as width 2 even though they are not ordinary listed 
EAW=A characters (U+E000..U+F8FF, U+F0000..U+FFFFD, U+100000..U+10FFFD) because the function falls 
back to mk_wcwidth(), the existing rules remain unchanged for everything else.
3. Put it together, the key distinction is that mk_wcwidth() uses width 1 for most EAW=A characters, 
while mk_wcwidth_cjk() changes the selected ambiguous characters to width 2 for compatibility with 
traditional CJK terminal behavior. The source explicitly says this variant is intended for users of 
CJK legacy encodings and is not generally recommended otherwise. 