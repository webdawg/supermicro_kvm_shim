package nn.pp.rc;

import java.awt.Component;
import java.awt.Graphics;
import java.awt.Label;
import java.awt.Menu;
import java.awt.MenuItem;
import java.awt.CheckboxMenuItem;
import java.awt.PopupMenu;
import java.awt.SystemColor;
import java.awt.event.ActionEvent;
import java.awt.event.ActionListener;
import java.awt.event.ItemEvent;
import java.awt.event.ItemListener;
import java.awt.event.MouseEvent;
import java.awt.event.MouseListener;
import java.awt.event.MouseMotionListener;

public class bm extends Label implements MouseListener, MouseMotionListener {
    private boolean hover;
    private PopupMenu menu;

    public bm(PopupMenu popupMenu) {
        super(popupMenu.getLabel(), Label.CENTER);
        hover = false;
        popupMenu.setLabel("");
        menu = popupMenu;
        wire(popupMenu, new Listener());
        add(menu);
        setBackground(SystemColor.control);
        addMouseListener(this);
        addMouseMotionListener(this);
    }

    private void wire(Menu m, Listener l) {
        for (int i = 0; i < m.getItemCount(); i++) {
            MenuItem item = m.getItem(i);
            if (item instanceof Menu) {
                wire((Menu) item, l);
            } else if (item instanceof CheckboxMenuItem) {
                ((CheckboxMenuItem) item).addItemListener(l);
            } else {
                item.addActionListener(l);
            }
        }
    }

    public void paint(Graphics g) {
        super.paint(g);
        if (hover) {
            int w = getSize().width - 1;
            int h = getSize().height - 1;
            g.setColor(SystemColor.controlHighlight);
            g.drawLine(0, 0, w, 0);
            g.drawLine(0, 0, 0, h);
            g.setColor(SystemColor.controlShadow);
            g.drawLine(0, h, w, h);
            g.drawLine(w, 0, w, h);
        }
    }

    public void update(Graphics g) {
        g.setColor(SystemColor.control);
        g.drawRect(0, 0, getSize().width - 1, getSize().height - 1);
        paint(g);
    }

    public void mouseEntered(MouseEvent e) { hover = true; repaint(); }
    public void mouseExited(MouseEvent e) { hover = false; repaint(); }

    public void mousePressed(MouseEvent e) {
        try {
            Label src = (Label) e.getSource();
            menu.show(src, 0, src.getSize().height);
        } catch (Throwable t) {
            // Legacy sun.awt.X11.XPopupMenuPeer.getCaptionSize() NPE
            // under headless Xvfb -- swallow it so a stuck popup grab
            // can't block subsequent mouse/keyboard delivery to the
            // real console canvas.
        }
    }

    public void mouseReleased(MouseEvent e) {}
    public void mouseClicked(MouseEvent e) {}
    public void mouseDragged(MouseEvent e) {}
    public void mouseMoved(MouseEvent e) {}

    private class Listener implements ActionListener, ItemListener {
        public void actionPerformed(ActionEvent e) {
            hover = false;
            repaint();
        }
        public void itemStateChanged(ItemEvent e) {
            hover = false;
            repaint();
        }
    }
}
