cardtype	equ	0ff00h
sdbuf		equ	cardtype + 1
cmd9data	equ	sdbuf + 15
cmd10data	equ	cmd9data + 16
cmd10dataend	equ	cmd10data + 16


ctUnknown	equ	-1
ctMMC		equ	0
ctSD1		equ	1
ctSD2		equ	2
ctSDH		equ	3

zero:
	di
	jp	chkmem

	defs	38h - $
	jp	inthandler

	defs	100h - $

starterr:
	xor	a
error:
	out	(01h), a	; port B = 00000000 / error code
	xor	a, e
	ld	bc, 0
err1:
	dec	c
	jr	nz, err1
	dec	b
	jr	nz, err1

	jr	error

start:
	ld	sp, 0ff00h
	call	init_ppi
	call	init_sd
	ld	e, 7
	jr	c, starterr
	ld	hl, 0
	ld	de, 0
	call	sd_read
	ld	e, 5
	jr	c, starterr
	ld	e, 2
	jr	starterr

init_ppi:

	ld	a, 0feh		;  
	out	(02h), a        ; port C = 11111110

	ld	a, 88h
	out	(03h), a	; port C7:C4 - input, C3:C0 - output, A, B - output
	ret

init_sd:
	call	sd_reset
	bit	7, a
	scf
	jr	nz, init_sd_ret

	ld	hl, cmd9data
	ld	de, cmd9data + 1
	ld	bc, cmd10dataend - cmd9data - 1
	ld	(hl), 0
	ldir

	call	sd_ver
	call	sd_info
init_sd_ret:
	ret

sd_reset:
	ld	a, 00000101b	; CS (C2) = 1
	out	(03h), a

	ld	b, 10
sd_r1:
	ld	a, 0ffh
	call	spi_wb
	djnz	sd_r1		; 10 * 8 clocks

	ld	bc, 6500	;
sd_r2:
	dec	c
	jr	nz, sd_r2
	dec	b
	jr	nz, sd_r2	; delay ~100ms	

	ld	a, 00000100b	; CS (C2) = 0
	out	(03h), a

	ld	c, 0
;	ld	hl, 0
;	ld	de, 0
;	jr	sd_cmd

sd_cmd_zarg:
	ld	hl, 0
	ld	d, h
	ld	e, l
	jr	sd_cmd

sd_acmd:
	push	bc
	push	de
	push	hl
	ld	c, 55
	call	sd_cmd_zarg
	call	sd_r4b
	pop	hl
	pop	de
	pop	bc

sd_cmd:
;	input:
;	C = CMD, HLDE = parameter
;	output:
;	A = result; bit7 = 0 if ok

	push	iy
	ld	iy, -6
	add	iy, sp
	ld	sp, iy

	ld	a, 3fh
	and	a, c
	or	a, 40h
	ld	(iy + 0), a
	ld	(iy + 1), h
	ld	(iy + 2), l
	ld	(iy + 3), d
	ld	(iy + 4), e

	ld	de, 1000
sd_cmd_pre:
	call	spi_rb
	inc	a
	jr	z, sd_cmd0
	dec	de
	ld	a, d
	or 	e
	jr	nz, sd_cmd_pre
	ld	a, 1
	jr	sd_cmd_ret

sd_cmd0:
	call	spi_rb
	call	spi_rb

	push	iy
	pop	hl
	ld	bc, 5
	ld	a, 0
	call	crc7
	add	a, a
	inc	a
	ld	(iy + 5), a
	push	iy
	pop	hl
	ld	bc, 6
	call	spi_wblock

	ld	b, 255
sd_cmd1:
	call	spi_rb
	bit	7, a
	jr	z, sd_cmd2
	djnz	sd_cmd1

sd_cmd2:
sd_cmd_ret:

	ld	iy, 6
	add	iy, sp
	ld	sp, iy
	pop	iy
	ret

sd_wt:
	push	bc
	ld	c, a
sd_wt1:
	call	spi_rb
	cp	a, c
	jr	nz, sd_wt1

	pop	bc
	ret

spi_wblock:
;	input:
;	HL = address, BC = len
;	output:
;	HL = address + len, BC = 0
	ld	a, (hl)
	call	spi_wb
	inc	hl
	dec	bc
	ld	a, b
	or	a, c
	jr	nz, spi_wblock
	ret

sd_r4b:
	ld	hl, sdbuf
	ld	bc, 4

spi_rblock:
	call	spi_rb
	ld	(hl), a
	inc 	hl
	dec	bc
	ld	a, b
	or	c
	jr	nz, spi_rblock
	ret

spi_rb:
	ld	a, 0ffh

spi_wb:
;	input:
;	A = byte to write
;	output:
;	A = byte read
	push	bc
	ld	b, 8
spiwb1:
	add	a, a		; bit7 (current) -> carry
	ld	c, a
	
	ld	a, 00000001b
	adc	a, a		; a = 00000010 | (current bit)

spiwb2:
	out	(03h), a	; MOSI (C1) = current bit

	ld	a, 00000001b	; CLK up
	out	(03h), a

	dec	a		; CLK down
	out	(03h), a

	in	a, (02h)	; read MISO (C7)
	add	a, a		; read bit -> carry
	ld	a, c
	adc	a, 0		; read bit -> A:0
	djnz	spiwb1

	pop	bc
	ret

sd_ver:
	ld	c, 8
	ld	hl, 0
	ld	de, 1aah
	call	sd_cmd

; if (t & 4)
	and	a, 4
	jr	z, sd_ver_2_0

; { // v1.x SD or not SD
;  spirb_(0, 4);
	call	sd_r4b

;  t = SD_cmd(58,0);
	ld	c, 58
	call	sd_cmd_zarg

;  if (t & 4)
;   { // not SD
;    return cardType=ctMMC;
;   }
	and	a, 4
	ld	a, ctMMC
	ld	(cardtype), a
	ret	nz

;    else
;    { // SD v1.X
;     getandprinthex(data, 4);
	call	sd_r4b
    
;     while (SD_acmd(41,0x00f80000) != 0)
;      {
;      }
sd_ver1:
	ld	c, 41
	ld	hl, 00f8h
	ld	de, 0
	call	sd_acmd
	or	a, a
	jr	nz, sd_ver1
		
;     getandprinthex(data, 4);
	call	sd_r4b

;     if (SD_cmd(9,0) != 0)
;      {
;      }
	ld	c, 9
	call	sd_cmd_zarg

;     if (spirbwt(cmd9data, 16, 0xfe) == -1) return -1;
	ld	a, 0feh
	ld	hl, cmd9data
	ld	bc, 16
	call	spirbwt
	ret	nz

;     if (SD_cmd(10,0) != 0)
;      {       
;      }
	ld	c, 10
	call	sd_cmd_zarg

;     if (spirbwt(cmd10data, 16, 0xfe) == -1) return -1;
	ld	a, 0feh
	ld	hl, cmd10data
	ld	bc, 16
	call	spirbwt
	ret	nz
     
;     if (SD_cmd(58,0) != 0)
;      {
;      }
	ld	c, 58
	call	sd_cmd_zarg
     
;     getandprinthex(data, 4);
	call	sd_r4b
     
;     if (SD_cmd(16,512) != 0)
;      {
;      }
	ld	c, 16
	ld	hl, 0
	ld	de, 512
	call	sd_cmd

;     getandprinthex(data, 4); 
	call	sd_r4b

;     return cardType = ctSD1;
	ld	a, ctSD1
	ld	(cardtype), a
	ret
;    }
; }

;  else

sd_ver_2_0:

;   { // SD v2.00 or later
;    cardType = ctSD2;
	ld	a, ctSD2
	ld	(cardtype), a
    
;    getandprinthex(data, 4); 
	call	sd_r4b

;    while (SD_acmd(41,0x40f80000) != 0)
;    {
;     spirb_(NULL, 4);
;    }
sd_ver_2_0_0:
	ld	c, 41
	ld	hl, 40f8h
	ld	de, 0
	call	sd_acmd
	or	a, a
	jr	z, sd_ver_2_0_1

	call	sd_r4b
	jr	sd_ver_2_0_0

sd_ver_2_0_1:
;    if (SD_acmd(59,1) != 0)
;    {
;    }
	ld	c, 59
	ld	hl, 0
	ld	de, 1
	call	sd_acmd

;    getandprinthex(data, 4); 
	call	sd_r4b
    
;    if (SD_cmd(9,0) != 0)
;     {
;     } 
	ld	c, 9
	call	sd_cmd_zarg

;    if (spirbwt(cmd9data, 16, 0xfe) == -1)
;    {
;    }
	ld	a, 0feh
	ld	hl, cmd9data
	ld	bc, 16
	call	spirbwt
	ret	nz

;    spirb();spirb(); // SDXC card sends 2 bytes (CRC?)
	call	spi_rb
	call	spi_rb

;    if (SD_cmd(10,0) != 0)
;     {
;     }
	ld	c, 10
	call	sd_cmd_zarg

;    if (spirbwt(cmd10data, 16, 0xfe) == -1)
;    {
;    }
	ld	a, 0feh
	ld	hl, cmd10data
	ld	bc, 16
	call	spirbwt
	ret	nz
    
;    spirb();spirb(); // SDXC card sends 2 bytes (CRC?)
	call	spi_rb
	call	spi_rb

;    if (SD_cmd(58,0) != 0)
;     {
;     }
	ld	c, 58
	call	sd_cmd_zarg
    
;    getandprinthex(data, 4); 
	call	sd_r4b
    
;    if (data[0] & 0x40) 
;     {
;      cardType = ctSDH;
;     }
	ld	a, (sdbuf)
	and	a, 40h
	jr	z, sd_ver_2_0_2
	ld	a, ctSDH
	ld	(cardtype), a

sd_ver_2_0_2:
;    if (SD_cmd(16,512) != 0)
;     {
;     }
	ld	c, 16
	ld	hl, 0
	ld	de, 512
	call	sd_cmd
    
;    getandprinthex(data, 4); 
	call	sd_r4b

;    return cardType;
;   }
	ld	a, (cardtype)
	ret

;	input:
;	A = token, HL = address, BC = len
;	output:
;	ZF if CRC OK

spirbwt:
	call	sd_wt
	push	bc
	push	hl
	call	spi_rblock
	pop	hl
	pop	bc
	ld	a, 0
	dec	bc
	call	crc7
	add	a, a
	inc	a
	dec	hl
	sub	a, (hl)
	ret

sd_info:
	ret

sd_read:
	ret

crc7:
;	input:
;	A = CRC, HL = address, BC = len
;	output:
;	A = CRC, HL = address + len, BC = 0
	push	de

crc7_r1:
	ld	d, (hl)
	
	push	bc
	ld	b, 8

crc7_r2:
	add	a, a
	ld	e, a
	xor	d
	ld	c, a	; din ^ (dout << 1)

	ld	a, 7fh
	and	a, e

	bit	7, c

	jr	z, crc7_l1

	xor	a, 9	; POLY = 9
	
crc7_l1:
	sla	d

	djnz	crc7_r2
	pop	bc

	ld	e, a
	inc	hl
	dec	bc
	ld	a, b
	or	c
	ld	a, e
	jr	nz, crc7_r1
	
	pop	de
	ret


inthandler:
	ret

chkmem:
	ld	ix, 0c000h
	jp	start
