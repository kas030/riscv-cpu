#ifndef __BOARD_H__
#define __BOARD_H__

#include <rtthread.h>

void rt_hw_board_init(void);
void rt_hw_seg_show_raw(const rt_uint8_t glyphs[8]);
void rt_hw_seg_release(void);

#endif /* __BOARD_H__ */
